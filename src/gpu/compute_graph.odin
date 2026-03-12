package gpu

import "core:mem"
import "core:fmt"

import parser "mimir:parser"
import binder "mimir:binder"
import checker "mimir:checker"

// Compute Graph — Operation DAG extracted from typed @gpu functions.
// This IR is what Phase 26 emits from and Phase 27 optimizes.

GPU_Node_ID :: distinct u32

GPU_Op_Kind :: enum {
	// Elementwise
	Add, Sub, Mul, Div, Neg, Abs,
	// Comparison
	Equal, Less, Greater, LessEq, GreaterEq,
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
	allocator:   mem.Allocator,
}

// Extract a compute graph from a validated @gpu function.
extract_graph :: proc(
	func: ^parser.Func_Def,
	bind_result: ^binder.Bind_Result,
	type_ctx: ^GPU_Type_Context,
	allocator: mem.Allocator,
) -> Compute_Graph {
	graph := Compute_Graph{
		nodes     = make([dynamic]GPU_Node, 0, 32, allocator),
		inputs    = make([dynamic]GPU_Node_ID, 0, 8, allocator),
		outputs   = make([dynamic]GPU_Node_ID, 0, 4, allocator),
		func_name = func.name,
		allocator = allocator,
	}

	ctx := GPU_Graph_Context{
		graph       = &graph,
		type_ctx    = type_ctx,
		bind_result = bind_result,
		env         = make(map[rawptr]GPU_Node_ID, 32, allocator),
		name_env    = make(map[string]GPU_Node_ID, 32, allocator),
		allocator   = allocator,
	}

	extract_params(func, &ctx)
	extract_stmts(func.body, &ctx)
	propagate_shapes(&graph, &ctx)

	return graph
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
		kind := binop_to_gpu_op(s.op)
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
		kind := binop_to_gpu_op(e.op)
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
		kind := cmpop_to_gpu_op(e.ops[0])
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
		name = fmt.tprintf("%d", v)
	case f64:
		output_type = checker.TYPE_FLOAT
		name = fmt.tprintf("%f", v)
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
		// Known activation/reduction functions
		kind: GPU_Op_Kind
		is_known := true
		switch f.id {
		case "relu":    kind = .ReLU
		case "sigmoid": kind = .Sigmoid
		case "tanh":    kind = .Tanh
		case "softmax": kind = .Softmax
		case "sum":     kind = .Sum
		case "mean":    kind = .Mean
		case "max":     kind = .Max
		case "min":     kind = .Min
		case "abs":     kind = .Abs
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
		// Method calls: x.sum(), x.mean(), x.T (handled in extract_expr), etc.
		kind: GPU_Op_Kind
		is_known := true
		switch f.attr {
		case "sum":       kind = .Sum
		case "mean":      kind = .Mean
		case "max":       kind = .Max
		case "min":       kind = .Min
		case "relu":      kind = .ReLU
		case "sigmoid":   kind = .Sigmoid
		case "tanh":      kind = .Tanh
		case "softmax":   kind = .Softmax
		case "transpose": kind = .Transpose
		case "reshape":   kind = .Reshape
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
		     .Equal, .Less, .Greater, .LessEq, .GreaterEq,
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
		case .Equal, .Less, .Greater, .LessEq, .GreaterEq,
		     .Transpose, .Param, .Constant, .Select, .Reshape, .Broadcast:
			other += 1
		}
	}
	return
}

// ==================== Helpers ====================

binop_to_gpu_op :: proc(op: parser.Binary_Op) -> GPU_Op_Kind {
	#partial switch op {
	case .Add:       return .Add
	case .Sub:       return .Sub
	case .Mult:      return .Mul
	case .Div:       return .Div
	case .Mat_Mult:  return .MatMul
	case: return .Add // fallback
	}
}

cmpop_to_gpu_op :: proc(op: parser.Cmp_Op) -> GPU_Op_Kind {
	#partial switch op {
	case .Eq:     return .Equal
	case .Lt:     return .Less
	case .Gt:     return .Greater
	case .Lt_E:   return .LessEq
	case .Gt_E:   return .GreaterEq
	case: return .Equal // fallback
	}
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
	case .Reshape:   return "Reshape"
	case .Broadcast: return "Broadcast"
	}
	return "Unknown"
}
