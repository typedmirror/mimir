package gpu

import "core:mem"
import "core:fmt"

import parser "mimir:parser"
import binder "mimir:binder"
import checker "mimir:checker"
import core   "mimir:core"

// Compute Graph — Operation DAG extracted from typed @gpu functions.
// This IR is what Phase 26 emits from and Phase 27 optimizes.

GPU_Node_ID :: distinct u32

GPU_Op_Kind :: enum {
	// Elementwise
	Add, Sub, Mul, Div, Neg, Abs,
	// Comparison
	Equal, NotEqual, Less, Greater, LessEq, GreaterEq,
	// Matrix
	MatMul, Transpose,
	// Reduction
	Sum, Mean, Max, Min,
	// Activation
	ReLU, Sigmoid, Tanh, Softmax,
	// Data
	Param,      // function parameter (graph input)
	Constant,   // literal numeric value
	Select,     // if/else → select(cond, true_val, false_val)
	// Shape
	Reshape, Broadcast,
	// Neural network (Phase 27)
	Conv2d, MaxPool2d, AvgPool2d, BatchNorm, Dropout, Flatten, CrossEntropy,
	// Math
	Exp, Log, Sqrt, Pow, Clamp,
}

GPU_Node :: struct {
	id:           GPU_Node_ID,
	kind:         GPU_Op_Kind,
	inputs:       []GPU_Node_ID,
	output_type:  checker.Type_ID,
	output_shape: []int,
	loc:          parser.Src_Loc,
	name:         string,
}

Compute_Graph :: struct {
	nodes:     [dynamic]GPU_Node,
	inputs:    [dynamic]GPU_Node_ID,
	outputs:   [dynamic]GPU_Node_ID,
	func_name: string,
	allocator: mem.Allocator,
}

GPU_Graph_Context :: struct {
	graph:       ^Compute_Graph,
	type_ctx:    ^GPU_Type_Context,
	bind_result: ^binder.Bind_Result,
	env:         map[rawptr]GPU_Node_ID, // AST node address → graph node
	name_env:    map[string]GPU_Node_ID, // variable name → graph node
	diagnostics: ^[dynamic]core.Diagnostic,
	file_path:   string,
	allocator:   mem.Allocator,
}

// Extract a compute graph from a validated @gpu function.
// Returns graph and any diagnostics (shape mismatches, unsupported ops, invalid types).
extract_graph :: proc(
	func: ^parser.Func_Def,
	bind_result: ^binder.Bind_Result,
	type_ctx: ^GPU_Type_Context,
	file_path: string,
	allocator: mem.Allocator,
) -> (Compute_Graph, []core.Diagnostic) {
	graph := Compute_Graph{
		nodes     = make([dynamic]GPU_Node, 0, 32, allocator),
		inputs    = make([dynamic]GPU_Node_ID, 0, 8, allocator),
		outputs   = make([dynamic]GPU_Node_ID, 0, 4, allocator),
		func_name = func.name,
		allocator = allocator,
	}

	diags := make([dynamic]core.Diagnostic, 0, 4, allocator)

	ctx := GPU_Graph_Context{
		graph       = &graph,
		type_ctx    = type_ctx,
		bind_result = bind_result,
		env         = make(map[rawptr]GPU_Node_ID, 32, allocator),
		name_env    = make(map[string]GPU_Node_ID, 32, allocator),
		diagnostics = &diags,
		file_path   = file_path,
		allocator   = allocator,
	}

	extract_params(func, &ctx)
	extract_stmts(func.body, &ctx)
	propagate_shapes(&graph, &ctx)

	// H1: Validate matmul shape compatibility
	validate_graph_shapes(&graph, &ctx)

	// H2: Check for unsupported ops that would produce wrong output
	check_unsupported_ops(&graph, &ctx)

	// H4: Check for INVALID_TYPE in output nodes
	validate_output_types(&graph, &ctx)

	return graph, diags[:]
}

// Create Param nodes for function arguments.
extract_params :: proc(func: ^parser.Func_Def, ctx: ^GPU_Graph_Context) {
	for arg in func.args.args {
		// Resolve parameter type annotation
		param_type := checker.INVALID_TYPE
		param_shape: []int = nil
		if arg.annotation != nil {
			tid := resolve_gpu_annotation(arg.annotation, ctx.type_ctx)
			if tid != checker.INVALID_TYPE {
				param_type = tid
				t := checker.get_type(ctx.type_ctx.reg, tid)
				#partial switch info in t.info {
				case checker.Tensor_Type:
					param_shape = info.shape
				}
			}
		}

		node_id := add_node(ctx.graph, GPU_Node{
			kind         = .Param,
			output_type  = param_type,
			output_shape = param_shape,
			loc          = arg.loc,
			name         = arg.arg,
		})
		append(&ctx.graph.inputs, node_id)
		ctx.name_env[arg.arg] = node_id
	}
}

// Extract statements into graph nodes.
extract_stmts :: proc(stmts: []parser.Stmt, ctx: ^GPU_Graph_Context) {
	for stmt in stmts {
		extract_stmt(stmt, ctx)
	}
}

extract_stmt :: proc(stmt: parser.Stmt, ctx: ^GPU_Graph_Context) {
	#partial switch s in stmt {
	case ^parser.Assign:
		node_id := extract_expr(s.value, ctx)
		if node_id == GPU_Node_ID(0) { return }
		// Bind to target names
		for target in s.targets {
			#partial switch t in target {
			case ^parser.Name_Expr:
				ctx.name_env[t.id] = node_id
			}
		}

	case ^parser.Ann_Assign:
		if s.value == nil { return }
		node_id := extract_expr(s.value, ctx)
		if node_id == GPU_Node_ID(0) { return }
		#partial switch t in s.target {
		case ^parser.Name_Expr:
			ctx.name_env[t.id] = node_id
		}

	case ^parser.Aug_Assign:
		// x += expr → x = x + expr
		lhs := extract_expr(s.target, ctx)
		rhs := extract_expr(s.value, ctx)
		if lhs == GPU_Node_ID(0) || rhs == GPU_Node_ID(0) { return }
		kind, op_ok := binop_to_gpu_op(s.op)
		if !op_ok {
			fmt.eprintfln("  gpu: unsupported augmented assignment operator in @gpu function")
			return
		}
		inputs := make([]GPU_Node_ID, 2, ctx.allocator)
		inputs[0] = lhs
		inputs[1] = rhs
		node_id := add_node(ctx.graph, GPU_Node{
			kind   = kind,
			inputs = inputs,
			loc    = s.loc,
		})
		#partial switch t in s.target {
		case ^parser.Name_Expr:
			ctx.name_env[t.id] = node_id
		}

	case ^parser.Return_Stmt:
		if s.value == nil { return }
		node_id := extract_expr(s.value, ctx)
		if node_id != GPU_Node_ID(0) {
			append(&ctx.graph.outputs, node_id)
		}

	case ^parser.If_Stmt:
		// Simple if/else → Select node
		extract_stmts(s.body, ctx)
		extract_stmts(s.orelse, ctx)

	case ^parser.For_Stmt:
		extract_stmts(s.body, ctx)

	case ^parser.Expr_Stmt:
		extract_expr(s.value, ctx)
	}
}

// Extract an expression into a graph node, returning its node ID.
// Returns GPU_Node_ID(0) for unsupported expressions.
extract_expr :: proc(expr: parser.Expr, ctx: ^GPU_Graph_Context) -> GPU_Node_ID {
	if expr == nil { return GPU_Node_ID(0) }

	#partial switch e in expr {
	case ^parser.Name_Expr:
		if node_id, ok := ctx.name_env[e.id]; ok {
			return node_id
		}
		// Check for known activation/reduction function names
		return GPU_Node_ID(0)

	case ^parser.Constant_Expr:
		return extract_constant(e, ctx)

	case ^parser.Bin_Op_Expr:
		left := extract_expr(e.left, ctx)
		right := extract_expr(e.right, ctx)
		if left == GPU_Node_ID(0) || right == GPU_Node_ID(0) { return GPU_Node_ID(0) }
		kind, op_ok := binop_to_gpu_op(e.op)
		if !op_ok {
			fmt.eprintfln("  gpu: unsupported operator in @gpu function (use +, -, *, /, @)")
			return GPU_Node_ID(0)
		}
		inputs := make([]GPU_Node_ID, 2, ctx.allocator)
		inputs[0] = left
		inputs[1] = right
		return add_node(ctx.graph, GPU_Node{
			kind   = kind,
			inputs = inputs,
			loc    = e.loc,
		})

	case ^parser.Unary_Op_Expr:
		operand := extract_expr(e.operand, ctx)
		if operand == GPU_Node_ID(0) { return GPU_Node_ID(0) }
		kind: GPU_Op_Kind
		#partial switch e.op {
		case .USub: kind = .Neg
		case .UAdd: return operand // no-op
		case: return GPU_Node_ID(0)
		}
		inputs := make([]GPU_Node_ID, 1, ctx.allocator)
		inputs[0] = operand
		return add_node(ctx.graph, GPU_Node{
			kind   = kind,
			inputs = inputs,
			loc    = e.loc,
		})

	case ^parser.Compare_Expr:
		// Only handle single comparison for now
		if len(e.ops) != 1 || len(e.comparators) != 1 { return GPU_Node_ID(0) }
		left := extract_expr(e.left, ctx)
		right := extract_expr(e.comparators[0], ctx)
		if left == GPU_Node_ID(0) || right == GPU_Node_ID(0) { return GPU_Node_ID(0) }
		kind, cmp_ok := cmpop_to_gpu_op(e.ops[0])
		if !cmp_ok {
			fmt.eprintfln("  gpu: unsupported comparison operator in @gpu function (use ==, !=, <, >, <=, >=)")
			return GPU_Node_ID(0)
		}
		inputs := make([]GPU_Node_ID, 2, ctx.allocator)
		inputs[0] = left
		inputs[1] = right
		return add_node(ctx.graph, GPU_Node{
			kind   = kind,
			inputs = inputs,
			loc    = e.loc,
		})

	case ^parser.Call_Expr:
		return extract_call(e, ctx)

	case ^parser.If_Expr:
		// Ternary → Select
		cond := extract_expr(e.test, ctx)
		true_val := extract_expr(e.body, ctx)
		false_val := extract_expr(e.orelse, ctx)
		if cond == GPU_Node_ID(0) || true_val == GPU_Node_ID(0) || false_val == GPU_Node_ID(0) {
			return GPU_Node_ID(0)
		}
		inputs := make([]GPU_Node_ID, 3, ctx.allocator)
		inputs[0] = cond
		inputs[1] = true_val
		inputs[2] = false_val
		return add_node(ctx.graph, GPU_Node{
			kind   = .Select,
			inputs = inputs,
			loc    = e.loc,
		})

	case ^parser.Subscript_Expr:
		// Tensor indexing — pass through for now
		return extract_expr(e.value, ctx)

	case ^parser.Attribute_Expr:
		// e.g. x.T for transpose
		base := extract_expr(e.value, ctx)
		if base == GPU_Node_ID(0) { return GPU_Node_ID(0) }
		if e.attr == "T" {
			inputs := make([]GPU_Node_ID, 1, ctx.allocator)
			inputs[0] = base
			return add_node(ctx.graph, GPU_Node{
				kind   = .Transpose,
				inputs = inputs,
				loc    = e.loc,
				name   = "T",
			})
		}
		return base
	}

	return GPU_Node_ID(0)
}

// Extract a constant expression to a Constant node.
extract_constant :: proc(c: ^parser.Constant_Expr, ctx: ^GPU_Graph_Context) -> GPU_Node_ID {
	output_type := checker.INVALID_TYPE
	name := ""

	#partial switch v in c.value {
	case i64:
		output_type = checker.TYPE_INT
		name = fmt.aprintf("%d", v, allocator = ctx.allocator)
	case f64:
		output_type = checker.TYPE_FLOAT
		name = fmt.aprintf("%f", v, allocator = ctx.allocator)
	case bool:
		output_type = checker.TYPE_BOOL
		name = "true" if v else "false"
	case:
		return GPU_Node_ID(0) // non-numeric constant
	}

	return add_node(ctx.graph, GPU_Node{
		kind        = .Constant,
		output_type = output_type,
		loc         = c.loc,
		name        = name,
	})
}

// Extract a function call — map known names to GPU ops.
extract_call :: proc(call: ^parser.Call_Expr, ctx: ^GPU_Graph_Context) -> GPU_Node_ID {
	#partial switch f in call.func {
	case ^parser.Name_Expr:
		// Known functions by name
		kind: GPU_Op_Kind
		is_known := true
		switch f.id {
		case "relu":           kind = .ReLU
		case "sigmoid":        kind = .Sigmoid
		case "tanh":           kind = .Tanh
		case "abs":            kind = .Abs
		case "softmax":        kind = .Softmax
		case "sum":            kind = .Sum
		case "mean":           kind = .Mean
		case "exp":            kind = .Exp
		case "log":            kind = .Log
		case "sqrt":           kind = .Sqrt
		case "pow":            kind = .Pow
		case "clamp":          kind = .Clamp
		case "conv2d":         kind = .Conv2d
		case "max_pool2d":     kind = .MaxPool2d
		case "avg_pool2d":     kind = .AvgPool2d
		case "batch_norm":     kind = .BatchNorm
		case "dropout":        kind = .Dropout
		case "flatten":        kind = .Flatten
		case "cross_entropy":  kind = .CrossEntropy
		case: is_known = false
		}
		if is_known {
			arg_ids := make([dynamic]GPU_Node_ID, 0, len(call.args), ctx.allocator)
			for arg in call.args {
				aid := extract_expr(arg, ctx)
				if aid != GPU_Node_ID(0) {
					append(&arg_ids, aid)
				}
			}
			inputs := make([]GPU_Node_ID, len(arg_ids), ctx.allocator)
			copy(inputs, arg_ids[:])
			return add_node(ctx.graph, GPU_Node{
				kind   = kind,
				inputs = inputs,
				loc    = call.loc,
				name   = f.id,
			})
		}

	case ^parser.Attribute_Expr:
		// Method calls: x.relu(), x.sum(), x.reshape(), etc.
		kind: GPU_Op_Kind
		is_known := true
		switch f.attr {
		case "relu":           kind = .ReLU
		case "sigmoid":        kind = .Sigmoid
		case "tanh":           kind = .Tanh
		case "reshape":        kind = .Reshape
		case "softmax":        kind = .Softmax
		case "sum":            kind = .Sum
		case "mean":           kind = .Mean
		case "max":            kind = .Max
		case "min":            kind = .Min
		case "transpose":      kind = .Transpose
		case "flatten":        kind = .Flatten
		case "exp":            kind = .Exp
		case "log":            kind = .Log
		case "sqrt":           kind = .Sqrt
		case "clamp":          kind = .Clamp
		case: is_known = false
		}
		if is_known {
			base := extract_expr(f.value, ctx)
			if base == GPU_Node_ID(0) { return GPU_Node_ID(0) }
			arg_ids := make([dynamic]GPU_Node_ID, 0, len(call.args) + 1, ctx.allocator)
			append(&arg_ids, base)
			for arg in call.args {
				aid := extract_expr(arg, ctx)
				if aid != GPU_Node_ID(0) {
					append(&arg_ids, aid)
				}
			}
			inputs := make([]GPU_Node_ID, len(arg_ids), ctx.allocator)
			copy(inputs, arg_ids[:])
			return add_node(ctx.graph, GPU_Node{
				kind   = kind,
				inputs = inputs,
				loc    = call.loc,
				name   = f.attr,
			})
		}
	}

	// Unknown call — extract args but return opaque node
	for arg in call.args {
		extract_expr(arg, ctx)
	}
	return GPU_Node_ID(0)
}

// Add a node to the graph, return its ID.
add_node :: proc(graph: ^Compute_Graph, node: GPU_Node) -> GPU_Node_ID {
	id := GPU_Node_ID(len(graph.nodes) + 1) // 1-indexed
	n := node
	n.id = id
	append(&graph.nodes, n)
	return id
}

// Get a node by ID (1-indexed).
get_node :: proc(graph: ^Compute_Graph, id: GPU_Node_ID) -> ^GPU_Node {
	idx := int(id) - 1
	if idx < 0 || idx >= len(graph.nodes) { return nil }
	return &graph.nodes[idx]
}

// Forward shape propagation through the graph.
propagate_shapes :: proc(graph: ^Compute_Graph, ctx: ^GPU_Graph_Context) {
	for &node in graph.nodes {
		if node.output_shape != nil { continue } // already set (e.g. Param)
		if len(node.inputs) == 0 { continue }

		switch node.kind {
		// Elementwise: broadcast shapes for binary ops, copy for unary
		case .Add, .Sub, .Mul, .Div, .Neg, .Abs,
		     .Equal, .NotEqual, .Less, .Greater, .LessEq, .GreaterEq,
		     .ReLU, .Sigmoid, .Tanh:
			first := get_node(graph, node.inputs[0])
			if first != nil && first.output_shape != nil {
				if len(node.inputs) >= 2 {
					second := get_node(graph, node.inputs[1])
					if second != nil && second.output_shape != nil {
						bcast, ok := broadcast_result_shape(first.output_shape, second.output_shape, ctx.allocator)
						if ok {
							node.output_shape = bcast
						} else {
							node.output_shape = first.output_shape
						}
					} else {
						node.output_shape = first.output_shape
					}
				} else {
					node.output_shape = first.output_shape
				}
				if node.output_type == checker.INVALID_TYPE {
					node.output_type = first.output_type
				}
			}

		// MatMul: [M, K] @ [K, N] → [M, N]
		case .MatMul:
			if len(node.inputs) >= 2 {
				a := get_node(graph, node.inputs[0])
				b := get_node(graph, node.inputs[1])
				if a != nil && b != nil && a.output_shape != nil && b.output_shape != nil {
					result, ok := matmul_result_shape(a.output_shape, b.output_shape, ctx.allocator)
					if ok {
						node.output_shape = result
						// Create tensor type with matmul result shape
						elem_type := checker.TYPE_FLOAT
						a_type := checker.get_type(ctx.type_ctx.reg, a.output_type)
						#partial switch ai in a_type.info {
						case checker.Tensor_Type:
							elem_type = ai.element_type
						}
						node.output_type = checker.make_tensor_type(ctx.type_ctx.reg, elem_type, result)
					}
				}
				if node.output_type == checker.INVALID_TYPE && a != nil {
					node.output_type = a.output_type
				}
			}

		// Transpose: reverse last two dims
		case .Transpose:
			first := get_node(graph, node.inputs[0])
			if first != nil && first.output_shape != nil && len(first.output_shape) >= 2 {
				n := len(first.output_shape)
				shape := make([]int, n, ctx.allocator)
				copy(shape, first.output_shape)
				shape[n-1], shape[n-2] = shape[n-2], shape[n-1]
				node.output_shape = shape
				if node.output_type == checker.INVALID_TYPE {
					node.output_type = first.output_type
				}
			}

		// Reduction: scalar output (shape [1])
		case .Sum, .Mean, .Max, .Min:
			first := get_node(graph, node.inputs[0])
			if first != nil {
				// Full reduction → scalar shape
				node.output_shape = make([]int, 1, ctx.allocator)
				node.output_shape[0] = 1
				if node.output_type == checker.INVALID_TYPE {
					node.output_type = first.output_type
				}
			}

		// Softmax: same shape
		case .Softmax:
			first := get_node(graph, node.inputs[0])
			if first != nil && first.output_shape != nil {
				node.output_shape = first.output_shape
				if node.output_type == checker.INVALID_TYPE {
					node.output_type = first.output_type
				}
			}

		// Select: shape of true branch
		case .Select:
			if len(node.inputs) >= 3 {
				true_node := get_node(graph, node.inputs[1])
				if true_node != nil && true_node.output_shape != nil {
					node.output_shape = true_node.output_shape
					if node.output_type == checker.INVALID_TYPE {
						node.output_type = true_node.output_type
					}
				}
			}

		// Broadcast: handled by elementwise when shapes differ
		case .Broadcast:
			first := get_node(graph, node.inputs[0])
			if first != nil && first.output_shape != nil {
				node.output_shape = first.output_shape
			}

		// Constant/Param: shape set at creation
		case .Param, .Constant:
			// Already set

		case .Reshape:
			first := get_node(graph, node.inputs[0])
			if first != nil {
				if first.output_shape != nil && node.output_shape != nil {
					inferred, ok := reshape_infer(first.output_shape, node.output_shape, ctx.allocator)
					if ok {
						node.output_shape = inferred
					}
				}
				if node.output_type == checker.INVALID_TYPE {
					node.output_type = first.output_type
				}
			}

		// Math: same shape as input (unary elementwise)
		case .Exp, .Log, .Sqrt:
			first := get_node(graph, node.inputs[0])
			if first != nil {
				node.output_shape = first.output_shape
				if node.output_type == checker.INVALID_TYPE {
					node.output_type = first.output_type
				}
			}

		// Pow/Clamp: binary/ternary elementwise — shape from first input
		case .Pow, .Clamp:
			first := get_node(graph, node.inputs[0])
			if first != nil {
				node.output_shape = first.output_shape
				if node.output_type == checker.INVALID_TYPE {
					node.output_type = first.output_type
				}
			}

		// Conv2d: [N, C_in, H, W] → [N, C_out, H_out, W_out]
		// inputs: [data, weight, (optional bias)]
		// weight shape: [C_out, C_in, KH, KW]
		case .Conv2d:
			if len(node.inputs) >= 2 {
				data := get_node(graph, node.inputs[0])
				weight := get_node(graph, node.inputs[1])
				if data != nil && weight != nil && data.output_shape != nil && weight.output_shape != nil {
					if len(data.output_shape) == 4 && len(weight.output_shape) == 4 {
						n := data.output_shape[0]
						c_out := weight.output_shape[0]
						h := data.output_shape[2]
						w := data.output_shape[3]
						kh := weight.output_shape[2]
						kw := weight.output_shape[3]
						// Default stride=1, padding=0
						h_out := h - kh + 1
						w_out := w - kw + 1
						if h_out > 0 && w_out > 0 {
							shape := make([]int, 4, ctx.allocator)
							shape[0] = n
							shape[1] = c_out
							shape[2] = h_out
							shape[3] = w_out
							node.output_shape = shape
						}
					}
				}
				if node.output_type == checker.INVALID_TYPE && data != nil {
					node.output_type = data.output_type
				}
			}

		// MaxPool2d / AvgPool2d: [N, C, H, W] → [N, C, H/K, W/K]
		case .MaxPool2d, .AvgPool2d:
			first := get_node(graph, node.inputs[0])
			if first != nil && first.output_shape != nil && len(first.output_shape) == 4 {
				// Default kernel_size=2, stride=kernel_size
				k := 2
				shape := make([]int, 4, ctx.allocator)
				shape[0] = first.output_shape[0]
				shape[1] = first.output_shape[1]
				shape[2] = first.output_shape[2] / k
				shape[3] = first.output_shape[3] / k
				node.output_shape = shape
				if node.output_type == checker.INVALID_TYPE {
					node.output_type = first.output_type
				}
			}

		// BatchNorm / Dropout: same shape as input
		case .BatchNorm, .Dropout:
			first := get_node(graph, node.inputs[0])
			if first != nil {
				node.output_shape = first.output_shape
				if node.output_type == checker.INVALID_TYPE {
					node.output_type = first.output_type
				}
			}

		// Flatten: [N, C, H, W] → [N, C*H*W]
		case .Flatten:
			first := get_node(graph, node.inputs[0])
			if first != nil && first.output_shape != nil && len(first.output_shape) >= 2 {
				flat_dim := 1
				for i := 1; i < len(first.output_shape); i += 1 {
					if first.output_shape[i] > 0 {
						flat_dim *= first.output_shape[i]
					} else {
						flat_dim = -1
						break
					}
				}
				shape := make([]int, 2, ctx.allocator)
				shape[0] = first.output_shape[0]
				shape[1] = flat_dim
				node.output_shape = shape
				if node.output_type == checker.INVALID_TYPE {
					node.output_type = first.output_type
				}
			}

		// CrossEntropy: [N, C] → [1] (scalar loss)
		case .CrossEntropy:
			shape := make([]int, 1, ctx.allocator)
			shape[0] = 1
			node.output_shape = shape
			if len(node.inputs) > 0 {
				first := get_node(graph, node.inputs[0])
				if first != nil && node.output_type == checker.INVALID_TYPE {
					node.output_type = first.output_type
				}
			}
		}
	}
}

// Print compute graph for debug/verbose output.
print_graph :: proc(graph: ^Compute_Graph) {
	fmt.printfln("    Graph: %d nodes", len(graph.nodes))
	for node in graph.nodes {
		kind_str := op_kind_string(node.kind)
		if len(node.name) > 0 {
			fmt.printfln("      [%d] %s '%s'", int(node.id), kind_str, node.name)
		} else {
			fmt.printfln("      [%d] %s", int(node.id), kind_str)
		}
		if len(node.inputs) > 0 {
			fmt.printf("        inputs:")
			for inp in node.inputs {
				fmt.printf(" %d", int(inp))
			}
			fmt.println()
		}
		if node.output_shape != nil {
			fmt.printf("        shape: [")
			for d, i in node.output_shape {
				if i > 0 { fmt.printf(", ") }
				fmt.printf("%d", d)
			}
			fmt.println("]")
		}
	}
}

// Count nodes by category for summary output.
count_ops :: proc(graph: ^Compute_Graph) -> (elementwise: int, matmul: int, reduction: int, other: int) {
	for node in graph.nodes {
		switch node.kind {
		case .Add, .Sub, .Mul, .Div, .Neg, .Abs,
		     .ReLU, .Sigmoid, .Tanh:
			elementwise += 1
		case .MatMul:
			matmul += 1
		case .Sum, .Mean, .Max, .Min, .Softmax:
			reduction += 1
		case .Exp, .Log, .Sqrt, .Pow, .Clamp:
			elementwise += 1
	case .Conv2d, .MaxPool2d, .AvgPool2d, .BatchNorm, .Flatten, .CrossEntropy:
			other += 1
	case .Equal, .NotEqual, .Less, .Greater, .LessEq, .GreaterEq,
		     .Transpose, .Param, .Constant, .Select, .Reshape, .Broadcast, .Dropout:
			other += 1
		}
	}
	return
}

// ==================== Helpers ====================

binop_to_gpu_op :: proc(op: parser.Binary_Op) -> (GPU_Op_Kind, bool) {
	#partial switch op {
	case .Add:       return .Add, true
	case .Sub:       return .Sub, true
	case .Mult:      return .Mul, true
	case .Div:       return .Div, true
	case .Mat_Mult:  return .MatMul, true
	}
	return .Add, false
}

cmpop_to_gpu_op :: proc(op: parser.Cmp_Op) -> (GPU_Op_Kind, bool) {
	#partial switch op {
	case .Eq:     return .Equal, true
	case .Not_Eq: return .NotEqual, true
	case .Lt:     return .Less, true
	case .Gt:     return .Greater, true
	case .Lt_E:   return .LessEq, true
	case .Gt_E:   return .GreaterEq, true
	}
	return .Equal, false
}

op_kind_string :: proc(kind: GPU_Op_Kind) -> string {
	switch kind {
	case .Add:       return "Add"
	case .Sub:       return "Sub"
	case .Mul:       return "Mul"
	case .Div:       return "Div"
	case .Neg:       return "Neg"
	case .Abs:       return "Abs"
	case .Equal:     return "Equal"
	case .NotEqual:  return "NotEqual"
	case .Less:      return "Less"
	case .Greater:   return "Greater"
	case .LessEq:    return "LessEq"
	case .GreaterEq: return "GreaterEq"
	case .MatMul:    return "MatMul"
	case .Transpose: return "Transpose"
	case .Sum:       return "Sum"
	case .Mean:      return "Mean"
	case .Max:       return "Max"
	case .Min:       return "Min"
	case .ReLU:      return "ReLU"
	case .Sigmoid:   return "Sigmoid"
	case .Tanh:      return "Tanh"
	case .Softmax:   return "Softmax"
	case .Param:     return "Param"
	case .Constant:  return "Constant"
	case .Select:    return "Select"
	case .Reshape:       return "Reshape"
	case .Broadcast:     return "Broadcast"
	case .Conv2d:        return "Conv2d"
	case .MaxPool2d:     return "MaxPool2d"
	case .AvgPool2d:     return "AvgPool2d"
	case .BatchNorm:     return "BatchNorm"
	case .Dropout:       return "Dropout"
	case .Flatten:       return "Flatten"
	case .CrossEntropy:  return "CrossEntropy"
	case .Exp:           return "Exp"
	case .Log:           return "Log"
	case .Sqrt:          return "Sqrt"
	case .Pow:           return "Pow"
	case .Clamp:         return "Clamp"
	}
	return "Unknown"
}

// ==================== Graph Validation ====================

// H1: Validate matmul shape compatibility — K dimensions must match.
validate_graph_shapes :: proc(graph: ^Compute_Graph, ctx: ^GPU_Graph_Context) {
	for &node in graph.nodes {
		if node.kind != .MatMul { continue }
		if len(node.inputs) < 2 { continue }

		a := get_node(graph, node.inputs[0])
		b := get_node(graph, node.inputs[1])
		if a == nil || b == nil { continue }
		if a.output_shape == nil || b.output_shape == nil { continue }
		if len(a.output_shape) < 2 || len(b.output_shape) < 2 { continue }

		k_a := a.output_shape[len(a.output_shape) - 1]
		k_b := b.output_shape[len(b.output_shape) - 2]

		// Skip symbolic dimensions
		if k_a == -1 || k_b == -1 { continue }

		if k_a != k_b {
			append(ctx.diagnostics, core.Diagnostic{
				severity = .Error,
				location = core.Location{
					file   = ctx.file_path,
					line   = int(node.loc.line),
					column = int(node.loc.col),
				},
				what = fmt.tprintf("matmul shape mismatch: left has K=%d, right has K=%d", k_a, k_b),
				why  = "matrix multiplication requires inner dimensions to match (A[M,K] @ B[K,N])",
				fix  = "ensure the inner dimensions of both matrices are equal",
				code = "GPU011",
			})
		}
	}
}

// H2: Check for unsupported ops that would produce wrong output.
// Phase 27: reduction, transpose, softmax are now supported with dedicated kernels.
check_unsupported_ops :: proc(graph: ^Compute_Graph, ctx: ^GPU_Graph_Context) {
	// All ops are now supported — this remains as a hook for future ops.
}

// H4: Validate output types — INVALID_TYPE means extraction failed silently.
validate_output_types :: proc(graph: ^Compute_Graph, ctx: ^GPU_Graph_Context) {
	for &node in graph.nodes {
		if node.kind == .Param { continue }
		if node.kind == .Constant { continue }
		if node.output_type == checker.INVALID_TYPE {
			append(ctx.diagnostics, core.Diagnostic{
				severity = .Error,
				location = core.Location{
					file   = ctx.file_path,
					line   = int(node.loc.line),
					column = int(node.loc.col),
				},
				what = fmt.tprintf("GPU graph node '%s' has unresolved type", op_kind_string(node.kind)),
				why  = "type annotation could not be resolved — the kernel cannot be compiled",
				fix  = "add explicit type annotations to all @gpu function parameters and return type",
				code = "GPU010",
			})
		}
	}
}
