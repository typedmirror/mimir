package gpu

import "core:mem"
import "core:fmt"
import "core:strings"

import checker "mimir:checker"

// PTX (NVIDIA virtual assembly) emission from compute graph.

emit_ptx :: proc(
	graph: ^Compute_Graph,
	type_ctx: ^GPU_Type_Context,
	bindings: ^Binding_Info,
	allocator: mem.Allocator,
) -> string {
	b := strings.builder_make(0, 2048, allocator)
	etype := element_type_str(wgsl_infer_element_type(graph, type_ctx), type_ctx, .PTX)
	is_float := etype == ".f32"

	// Header
	fmt.sbprint(&b, ".version 7.0\n")
	fmt.sbprint(&b, ".target sm_70\n")
	fmt.sbprint(&b, ".address_size 64\n\n")

	// Entry point
	fmt.sbprintf(&b, ".visible .entry kernel_%s(\n", graph.func_name)

	// Parameters (all are pointers)
	for inp, idx in graph.inputs {
		node := get_node(graph, inp)
		name := "param"
		if node != nil && len(node.name) > 0 { name = node.name }
		fmt.sbprintf(&b, "    .param .u64 param_%s", name)
		if idx < len(graph.inputs) - 1 || len(graph.outputs) > 0 {
			fmt.sbprint(&b, ",\n")
		} else {
			fmt.sbprint(&b, "\n")
		}
	}
	for _, idx in graph.outputs {
		fmt.sbprintf(&b, "    .param .u64 result")
		if idx < len(graph.outputs) - 1 {
			fmt.sbprint(&b, ",\n")
		} else {
			fmt.sbprint(&b, "\n")
		}
	}

	fmt.sbprint(&b, ") {\n")

	// Register declarations
	fmt.sbprint(&b, "    .reg .u32 %tid;\n")
	fmt.sbprint(&b, "    .reg .u64 %off, %addr;\n")

	// Count how many virtual registers we need
	vreg_count := len(graph.nodes) + len(graph.inputs) + 4
	reg_type := etype  // ".f32", ".s32", ".f16", ".f64", ".s64"
	fmt.sbprintf(&b, "    .reg %s %%v<%d>;\n", reg_type, vreg_count)
	fmt.sbprintf(&b, "    .reg .u64 %%p<%d>;\n", len(graph.inputs) + len(graph.outputs) + 2)
	fmt.sbprint(&b, "\n")

	// Get thread ID — stride by element size
	stride := 4  // f32/s32 = 4 bytes
	if etype == ".f64" || etype == ".s64" { stride = 8 }
	else if etype == ".f16" { stride = 2 }
	fmt.sbprint(&b, "    mov.u32 %tid, %tid.x;\n")
	fmt.sbprintf(&b, "    mul.wide.u32 %%off, %%tid, %d;\n\n", stride)

	// Load parameters from buffers
	for inp, pidx in graph.inputs {
		node := get_node(graph, inp)
		name := "param"
		if node != nil && len(node.name) > 0 { name = node.name }
		fmt.sbprintf(&b, "    ld.param.u64 %%p%d, [param_%s];\n", pidx, name)
		fmt.sbprintf(&b, "    add.u64 %%p%d, %%p%d, %%off;\n", pidx, pidx)
		if is_float {
			fmt.sbprintf(&b, "    ld.global.f32 %%v%d, [%%p%d];\n", int(inp), pidx)
		} else {
			fmt.sbprintf(&b, "    ld.global.s32 %%v%d, [%%p%d];\n", int(inp), pidx)
		}
	}
	fmt.sbprint(&b, "\n")

	// Emit compute nodes
	for &node in graph.nodes {
		if node.kind == .Param { continue }
		ptx_emit_node(&b, graph, &node, etype, is_float)
	}

	// Store outputs
	out_pidx := len(graph.inputs)
	for out in graph.outputs {
		fmt.sbprintf(&b, "    ld.param.u64 %%p%d, [result];\n", out_pidx)
		fmt.sbprintf(&b, "    add.u64 %%p%d, %%p%d, %%off;\n", out_pidx, out_pidx)
		if is_float {
			fmt.sbprintf(&b, "    st.global.f32 [%%p%d], %%v%d;\n", out_pidx, int(out))
		} else {
			fmt.sbprintf(&b, "    st.global.s32 [%%p%d], %%v%d;\n", out_pidx, int(out))
		}
		out_pidx += 1
	}

	fmt.sbprint(&b, "\n    ret;\n")
	fmt.sbprint(&b, "}\n")
	return strings.to_string(b)
}

ptx_emit_node :: proc(
	b: ^strings.Builder,
	graph: ^Compute_Graph,
	node: ^GPU_Node,
	etype: string,
	is_float: bool,
) {
	id := int(node.id)
	op_suffix := etype // ".f32" or ".s32"

	switch node.kind {
	case .Param:
		// Already loaded

	case .Constant:
		if is_float {
			fmt.sbprintf(b, "    mov.f32 %%v%d, %s;\n", id, ptx_float_literal(node.name))
		} else {
			fmt.sbprintf(b, "    mov.s32 %%v%d, %s;\n", id, node.name)
		}

	case .Add:
		fmt.sbprintf(b, "    add%s %%v%d, %%v%d, %%v%d;\n", op_suffix, id, int(node.inputs[0]), int(node.inputs[1]))
	case .Sub:
		fmt.sbprintf(b, "    sub%s %%v%d, %%v%d, %%v%d;\n", op_suffix, id, int(node.inputs[0]), int(node.inputs[1]))
	case .Mul:
		fmt.sbprintf(b, "    mul%s %%v%d, %%v%d, %%v%d;\n", op_suffix, id, int(node.inputs[0]), int(node.inputs[1]))
	case .Div:
		if is_float {
			fmt.sbprintf(b, "    div.rn.f32 %%v%d, %%v%d, %%v%d;\n", id, int(node.inputs[0]), int(node.inputs[1]))
		} else {
			fmt.sbprintf(b, "    div.s32 %%v%d, %%v%d, %%v%d;\n", id, int(node.inputs[0]), int(node.inputs[1]))
		}

	case .Neg:
		fmt.sbprintf(b, "    neg%s %%v%d, %%v%d;\n", op_suffix, id, int(node.inputs[0]))
	case .Abs:
		fmt.sbprintf(b, "    abs%s %%v%d, %%v%d;\n", op_suffix, id, int(node.inputs[0]))

	case .ReLU:
		if is_float {
			fmt.sbprintf(b, "    max.f32 %%v%d, %%v%d, 0f00000000;\n", id, int(node.inputs[0]))
		} else {
			fmt.sbprintf(b, "    max.s32 %%v%d, %%v%d, 0;\n", id, int(node.inputs[0]))
		}

	case .Sigmoid:
		if !is_float {
			// Sigmoid is meaningless for integer types — passthrough
			fmt.sbprintf(b, "    mov%s %%v%d, %%v%d; // sigmoid: integer passthrough\n", op_suffix, id, int(node.inputs[0]))
			return
		}
		// 1 / (1 + exp(-x)), using ex2: exp(x) = ex2(x * log2(e)), log2(e) = 0x3FB8AA3B
		fmt.sbprintf(b, "    neg.f32 %%v%d, %%v%d;\n", id, int(node.inputs[0]))
		fmt.sbprintf(b, "    mul.f32 %%v%d, %%v%d, 0f3FB8AA3B; // * log2(e)\n", id, id)
		fmt.sbprintf(b, "    ex2.approx.f32 %%v%d, %%v%d;\n", id, id)
		fmt.sbprintf(b, "    add.f32 %%v%d, %%v%d, 0f3F800000; // +1.0\n", id, id)
		fmt.sbprintf(b, "    rcp.approx.f32 %%v%d, %%v%d;\n", id, id)

	case .Tanh:
		if !is_float {
			fmt.sbprintf(b, "    mov%s %%v%d, %%v%d; // tanh: integer passthrough\n", op_suffix, id, int(node.inputs[0]))
			return
		}
		// tanh(x) = (exp(2x) - 1) / (exp(2x) + 1)
		// Using ex2: exp(x) ≈ ex2(x * log2(e)), log2(e) = 0x3FB8AA3B
		// Need temp registers: t1=2x, t2=exp(2x), t3=num, result=tanh
		in0 := int(node.inputs[0])
		t1 := id     // reuse output register for intermediate
		t2 := id + 1000  // temp register offset (safe — vreg pool is oversized)
		fmt.sbprintf(b, "    .reg .f32 %%tanh_t%d;\n", id)
		fmt.sbprintf(b, "    add.f32 %%v%d, %%v%d, %%v%d; // 2x\n", t1, in0, in0)
		fmt.sbprintf(b, "    mul.f32 %%v%d, %%v%d, 0f3FB8AA3B; // 2x * log2(e)\n", t1, t1)
		fmt.sbprintf(b, "    ex2.approx.f32 %%tanh_t%d, %%v%d; // exp(2x)\n", id, t1)
		fmt.sbprintf(b, "    sub.f32 %%v%d, %%tanh_t%d, 0f3F800000; // exp(2x) - 1\n", t1, id)
		fmt.sbprintf(b, "    add.f32 %%tanh_t%d, %%tanh_t%d, 0f3F800000; // exp(2x) + 1\n", id, id)
		fmt.sbprintf(b, "    div.approx.f32 %%v%d, %%v%d, %%tanh_t%d; // tanh\n", id, t1, id)

	case .Softmax:
		if len(node.inputs) > 0 {
			fmt.sbprintf(b, "    mov%s %%v%d, %%v%d; // softmax: needs shared mem reduction\n", op_suffix, id, int(node.inputs[0]))
		}

	case .Equal, .NotEqual, .Less, .Greater, .LessEq, .GreaterEq:
		cmp_op := "eq"
		#partial switch node.kind {
		case .NotEqual:  cmp_op = "ne"
		case .Less:      cmp_op = "lt"
		case .Greater:   cmp_op = "gt"
		case .LessEq:    cmp_op = "le"
		case .GreaterEq: cmp_op = "ge"
		case:
		}
		fmt.sbprintf(b, "    .reg .pred %%cmp%d;\n", id)
		fmt.sbprintf(b, "    setp.%s%s %%cmp%d, %%v%d, %%v%d;\n", cmp_op, op_suffix, id, int(node.inputs[0]), int(node.inputs[1]))
		if is_float {
			fmt.sbprintf(b, "    selp.f32 %%v%d, 0f3F800000, 0f00000000, %%cmp%d;\n", id, id)
		} else {
			fmt.sbprintf(b, "    selp.s32 %%v%d, 1, 0, %%cmp%d;\n", id, id)
		}

	case .Select:
		if len(node.inputs) >= 3 {
			fmt.sbprintf(b, "    .reg .pred %%sel%d;\n", id)
			if is_float {
				fmt.sbprintf(b, "    setp.gt.f32 %%sel%d, %%v%d, 0f00000000;\n", id, int(node.inputs[0]))
			} else {
				fmt.sbprintf(b, "    setp.gt.s32 %%sel%d, %%v%d, 0;\n", id, int(node.inputs[0]))
			}
			fmt.sbprintf(b, "    selp%s %%v%d, %%v%d, %%v%d, %%sel%d;\n", op_suffix, id, int(node.inputs[1]), int(node.inputs[2]), id)
		}

	case .MatMul, .Transpose, .Sum, .Mean, .Max, .Min, .Reshape, .Broadcast:
		if len(node.inputs) > 0 {
			fmt.sbprintf(b, "    mov%s %%v%d, %%v%d; // %s passthrough\n",
				op_suffix, id, int(node.inputs[0]), op_kind_string(node.kind))
		}

	// Phase 27: new ops — PTX stubs
	case .Exp:
		if is_float {
			fmt.sbprintf(b, "    mul.f32 %%v%d, %%v%d, 0f3FB8AA3B; // * log2(e)\n", id, int(node.inputs[0]))
			fmt.sbprintf(b, "    ex2.approx.f32 %%v%d, %%v%d;\n", id, id)
		} else {
			fmt.sbprintf(b, "    mov%s %%v%d, %%v%d; // exp: integer passthrough\n", op_suffix, id, int(node.inputs[0]))
		}
	case .Log:
		if is_float {
			fmt.sbprintf(b, "    lg2.approx.f32 %%v%d, %%v%d;\n", id, int(node.inputs[0]))
			fmt.sbprintf(b, "    mul.f32 %%v%d, %%v%d, 0f3F317218; // * ln(2)\n", id, id)
		} else {
			fmt.sbprintf(b, "    mov%s %%v%d, %%v%d; // log: integer passthrough\n", op_suffix, id, int(node.inputs[0]))
		}
	case .Sqrt:
		if is_float {
			fmt.sbprintf(b, "    sqrt.approx.f32 %%v%d, %%v%d;\n", id, int(node.inputs[0]))
		} else {
			fmt.sbprintf(b, "    mov%s %%v%d, %%v%d; // sqrt: integer passthrough\n", op_suffix, id, int(node.inputs[0]))
		}
	case .Pow, .Clamp, .Conv2d, .MaxPool2d, .AvgPool2d, .BatchNorm, .Dropout, .Flatten, .CrossEntropy:
		if len(node.inputs) > 0 {
			fmt.sbprintf(b, "    mov%s %%v%d, %%v%d; // %s: PTX stub\n",
				op_suffix, id, int(node.inputs[0]), op_kind_string(node.kind))
		}
	}
}

ptx_float_literal :: proc(name: string) -> string {
	// PTX float literals can be decimal or hex IEEE 754
	// For simplicity, use the string as-is if it has a decimal point
	for c in name {
		if c == '.' { return name }
	}
	return fmt.tprintf("%s.0", name)
}
