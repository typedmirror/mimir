package gpu

import "core:mem"
import "core:fmt"
import "core:strings"

import checker "mimir:checker"

// Metal Shading Language emission from compute graph.

emit_msl :: proc(
	graph: ^Compute_Graph,
	type_ctx: ^GPU_Type_Context,
	bindings: ^Binding_Info,
	allocator: mem.Allocator,
) -> string {
	b := strings.builder_make(0, 2048, allocator)
	etype := element_type_str(wgsl_infer_element_type(graph, type_ctx), type_ctx, .MSL)
	use_matmul := has_matmul(graph)

	fmt.sbprint(&b, "#include <metal_stdlib>\nusing namespace metal;\n\n")

	// Kernel signature
	fmt.sbprintf(&b, "kernel void kernel_%s(\n", graph.func_name)

	// Parameter buffers
	for inp in graph.inputs {
		node := get_node(graph, inp)
		if node == nil { continue }
		binding, has_binding := bindings.param_bindings[inp]
		if !has_binding { continue }
		fmt.sbprintf(&b, "    device const %s* param_%s [[buffer(%d)]],\n",
			etype, node.name, binding)
	}
	// Output buffer
	for out in graph.outputs {
		binding, has_out_binding := bindings.output_bindings[out]
		if !has_out_binding { continue }
		fmt.sbprintf(&b, "    device %s* result [[buffer(%d)]],\n", etype, binding)
	}

	// Thread ID
	if use_matmul {
		fmt.sbprint(&b, "    constant uint3& dims [[buffer(")
		fmt.sbprintf(&b, "%d", bindings.total_bindings)
		fmt.sbprint(&b, ")]],\n")
		fmt.sbprint(&b, "    uint2 gid [[thread_position_in_grid]]\n")
	} else {
		fmt.sbprint(&b, "    uint tid [[thread_position_in_grid]]\n")
	}
	fmt.sbprint(&b, ") {\n")

	if use_matmul {
		fmt.sbprint(&b, "    uint row = gid.x;\n")
		fmt.sbprint(&b, "    uint col = gid.y;\n")
		fmt.sbprint(&b, "    uint M = dims.x, K = dims.y, N = dims.z;\n")
	}

	// Emit nodes
	for &node in graph.nodes {
		msl_emit_node(&b, graph, &node, bindings, etype, use_matmul)
	}

	// Store outputs
	for out in graph.outputs {
		if use_matmul {
			fmt.sbprintf(&b, "    result[row * N + col] = v%d;\n", int(out))
		} else {
			fmt.sbprintf(&b, "    result[tid] = v%d;\n", int(out))
		}
	}

	fmt.sbprint(&b, "}\n")
	return strings.to_string(b)
}

msl_emit_node :: proc(
	b: ^strings.Builder,
	graph: ^Compute_Graph,
	node: ^GPU_Node,
	bindings: ^Binding_Info,
	etype: string,
	use_matmul: bool,
) {
	id := int(node.id)

	switch node.kind {
	case .Param:
		if !use_matmul {
			fmt.sbprintf(b, "    %s v%d = param_%s[tid];\n", etype, id, node.name)
		}

	case .Constant:
		fmt.sbprintf(b, "    %s v%d = %s;\n", etype, id, msl_const_value(node.name, etype))

	case .Add:
		a, c := msl_binary_inputs(graph, node, bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = %s + %s;\n", etype, id, a, c)
	case .Sub:
		a, c := msl_binary_inputs(graph, node, bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = %s - %s;\n", etype, id, a, c)
	case .Mul:
		a, c := msl_binary_inputs(graph, node, bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = %s * %s;\n", etype, id, a, c)
	case .Div:
		a, c := msl_binary_inputs(graph, node, bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = %s / %s;\n", etype, id, a, c)

	case .Neg:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = -%s;\n", etype, id, a)
	case .Abs:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = metal::abs(%s);\n", etype, id, a)

	case .Equal:
		a, c := msl_binary_inputs(graph, node, bindings, use_matmul)
		t, f := msl_cmp_literals(etype)
		fmt.sbprintf(b, "    %s v%d = (%s == %s) ? %s : %s;\n", etype, id, a, c, t, f)
	case .NotEqual:
		a, c := msl_binary_inputs(graph, node, bindings, use_matmul)
		t, f := msl_cmp_literals(etype)
		fmt.sbprintf(b, "    %s v%d = (%s != %s) ? %s : %s;\n", etype, id, a, c, t, f)
	case .Less:
		a, c := msl_binary_inputs(graph, node, bindings, use_matmul)
		t, f := msl_cmp_literals(etype)
		fmt.sbprintf(b, "    %s v%d = (%s < %s) ? %s : %s;\n", etype, id, a, c, t, f)
	case .Greater:
		a, c := msl_binary_inputs(graph, node, bindings, use_matmul)
		t, f := msl_cmp_literals(etype)
		fmt.sbprintf(b, "    %s v%d = (%s > %s) ? %s : %s;\n", etype, id, a, c, t, f)
	case .LessEq:
		a, c := msl_binary_inputs(graph, node, bindings, use_matmul)
		t, f := msl_cmp_literals(etype)
		fmt.sbprintf(b, "    %s v%d = (%s <= %s) ? %s : %s;\n", etype, id, a, c, t, f)
	case .GreaterEq:
		a, c := msl_binary_inputs(graph, node, bindings, use_matmul)
		t, f := msl_cmp_literals(etype)
		fmt.sbprintf(b, "    %s v%d = (%s >= %s) ? %s : %s;\n", etype, id, a, c, t, f)

	case .ReLU:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = metal::max(%s, (%s)0);\n", etype, id, a, etype)
	case .Sigmoid:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = 1.0f / (1.0f + metal::exp(-%s));\n", etype, id, a)
	case .Tanh:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = metal::tanh(%s);\n", etype, id, a)

	case .Softmax:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    // Softmax: exp(x - max) / sum(exp(x - max))\n")
		fmt.sbprintf(b, "    threadgroup %s sm_%d[256];\n", etype, id)
		fmt.sbprintf(b, "    sm_%d[tid %% 256] = %s;\n", id, a)
		fmt.sbprintf(b, "    threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    for (uint s = 128; s > 0; s >>= 1) {{\n")
		fmt.sbprintf(b, "        if (tid %% 256 < s) sm_%d[tid %% 256] = metal::max(sm_%d[tid %% 256], sm_%d[tid %% 256 + s]);\n", id, id, id)
		fmt.sbprintf(b, "        threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    }}\n")
		fmt.sbprintf(b, "    %s sm_max_%d = sm_%d[0];\n", etype, id, id)
		fmt.sbprintf(b, "    %s sm_exp_%d = metal::exp(%s - sm_max_%d);\n", etype, id, a, id)
		fmt.sbprintf(b, "    sm_%d[tid %% 256] = sm_exp_%d;\n", id, id)
		fmt.sbprintf(b, "    threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    for (uint s = 128; s > 0; s >>= 1) {{\n")
		fmt.sbprintf(b, "        if (tid %% 256 < s) sm_%d[tid %% 256] += sm_%d[tid %% 256 + s];\n", id, id)
		fmt.sbprintf(b, "        threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    }}\n")
		fmt.sbprintf(b, "    %s v%d = sm_exp_%d / sm_%d[0];\n", etype, id, id, id)

	case .MatMul:
		if len(node.inputs) >= 2 {
			a_node := get_node(graph, node.inputs[0])
			b_node := get_node(graph, node.inputs[1])
			a_name := fmt.tprintf("v%d", int(node.inputs[0]))
			b_name := fmt.tprintf("v%d", int(node.inputs[1]))
			if a_node != nil && a_node.kind == .Param && len(a_node.name) > 0 { a_name = fmt.tprintf("param_%s", a_node.name) }
			if b_node != nil && b_node.kind == .Param && len(b_node.name) > 0 { b_name = fmt.tprintf("param_%s", b_node.name) }
			fmt.sbprintf(b, "    %s v%d = 0;\n", etype, id)
			fmt.sbprintf(b, "    for (uint k = 0; k < K; k++) {{\n")
			fmt.sbprintf(b, "        v%d += %s[row * K + k] * %s[k * N + col];\n", id, a_name, b_name)
			fmt.sbprintf(b, "    }}\n")
		}

	case .Transpose:
		a_node := get_node(graph, node.inputs[0])
		if a_node != nil && a_node.kind == .Param && len(a_node.name) > 0 {
			fmt.sbprintf(b, "    // Transpose: shared memory tile (16x17 for bank avoidance)\n")
			fmt.sbprintf(b, "    threadgroup %s tile_%d[16][17];\n", etype, id)
			fmt.sbprintf(b, "    uint tx_%d = tid %% 16, ty_%d = (tid / 16) %% 16;\n", id, id)
			fmt.sbprintf(b, "    tile_%d[ty_%d][tx_%d] = param_%s[ty_%d * 16 + tx_%d];\n", id, id, id, a_node.name, id, id)
			fmt.sbprintf(b, "    threadgroup_barrier(mem_flags::mem_threadgroup);\n")
			fmt.sbprintf(b, "    %s v%d = tile_%d[tx_%d][ty_%d];\n", etype, id, id, id, id)
		} else {
			a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
			fmt.sbprintf(b, "    %s v%d = %s; // transpose\n", etype, id, a)
		}

	case .Sum:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    threadgroup %s sh_%d[256];\n", etype, id)
		fmt.sbprintf(b, "    sh_%d[tid %% 256] = %s;\n", id, a)
		fmt.sbprintf(b, "    threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    for (uint s = 128; s > 0; s >>= 1) {{\n")
		fmt.sbprintf(b, "        if (tid %% 256 < s) sh_%d[tid %% 256] += sh_%d[tid %% 256 + s];\n", id, id)
		fmt.sbprintf(b, "        threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    }}\n")
		fmt.sbprintf(b, "    %s v%d = sh_%d[0];\n", etype, id, id)

	case .Mean:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    threadgroup %s sh_%d[256];\n", etype, id)
		fmt.sbprintf(b, "    sh_%d[tid %% 256] = %s;\n", id, a)
		fmt.sbprintf(b, "    threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    for (uint s = 128; s > 0; s >>= 1) {{\n")
		fmt.sbprintf(b, "        if (tid %% 256 < s) sh_%d[tid %% 256] += sh_%d[tid %% 256 + s];\n", id, id)
		fmt.sbprintf(b, "        threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    }}\n")
		fmt.sbprintf(b, "    %s v%d = sh_%d[0] / (%s)256;\n", etype, id, id, etype)

	case .Max:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    threadgroup %s sh_%d[256];\n", etype, id)
		fmt.sbprintf(b, "    sh_%d[tid %% 256] = %s;\n", id, a)
		fmt.sbprintf(b, "    threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    for (uint s = 128; s > 0; s >>= 1) {{\n")
		fmt.sbprintf(b, "        if (tid %% 256 < s) sh_%d[tid %% 256] = metal::max(sh_%d[tid %% 256], sh_%d[tid %% 256 + s]);\n", id, id, id)
		fmt.sbprintf(b, "        threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    }}\n")
		fmt.sbprintf(b, "    %s v%d = sh_%d[0];\n", etype, id, id)

	case .Min:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    threadgroup %s sh_%d[256];\n", etype, id)
		fmt.sbprintf(b, "    sh_%d[tid %% 256] = %s;\n", id, a)
		fmt.sbprintf(b, "    threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    for (uint s = 128; s > 0; s >>= 1) {{\n")
		fmt.sbprintf(b, "        if (tid %% 256 < s) sh_%d[tid %% 256] = metal::min(sh_%d[tid %% 256], sh_%d[tid %% 256 + s]);\n", id, id, id)
		fmt.sbprintf(b, "        threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    }}\n")
		fmt.sbprintf(b, "    %s v%d = sh_%d[0];\n", etype, id, id)

	case .Select:
		if len(node.inputs) >= 3 {
			cond := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
			tv := msl_input_ref(graph, node.inputs[1], bindings, use_matmul)
			fv := msl_input_ref(graph, node.inputs[2], bindings, use_matmul)
			fmt.sbprintf(b, "    %s v%d = (%s > 0) ? %s : %s;\n", etype, id, cond, tv, fv)
		}

	case .Reshape, .Broadcast:
		if len(node.inputs) > 0 {
			a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
			fmt.sbprintf(b, "    %s v%d = %s;\n", etype, id, a)
		}

	// Math ops
	case .Exp:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = metal::exp(%s);\n", etype, id, a)
	case .Log:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = metal::log(%s);\n", etype, id, a)
	case .Sqrt:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = metal::sqrt(%s);\n", etype, id, a)
	case .Pow:
		a, c := msl_binary_inputs(graph, node, bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = metal::pow(%s, %s);\n", etype, id, a, c)
	case .Clamp:
		if len(node.inputs) >= 3 {
			a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
			lo := msl_input_ref(graph, node.inputs[1], bindings, use_matmul)
			hi := msl_input_ref(graph, node.inputs[2], bindings, use_matmul)
			fmt.sbprintf(b, "    %s v%d = metal::clamp(%s, %s, %s);\n", etype, id, a, lo, hi)
		} else if len(node.inputs) >= 1 {
			a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
			fmt.sbprintf(b, "    %s v%d = %s;\n", etype, id, a)
		}

	// NN ops
	case .Conv2d:
		fmt.sbprintf(b, "    %s v%d = 0; // conv2d: TODO kernel loops\n", etype, id)
	case .MaxPool2d:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = %s; // maxpool passthrough\n", etype, id, a)
	case .AvgPool2d:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = %s; // avgpool passthrough\n", etype, id, a)
	case .BatchNorm:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = %s; // batchnorm inference\n", etype, id, a)
	case .Dropout:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = %s; // dropout identity\n", etype, id, a)
	case .Flatten:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = %s; // flatten reshape\n", etype, id, a)
	case .CrossEntropy:
		if len(node.inputs) >= 1 {
			logits := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
			fmt.sbprintf(b, "    %s v%d = -metal::log(metal::exp(%s) / (metal::exp(%s) + 1.0f));\n", etype, id, logits, logits)
		}
	}
}

msl_input_ref :: proc(graph: ^Compute_Graph, nid: GPU_Node_ID, bindings: ^Binding_Info, use_matmul: bool) -> string {
	node := get_node(graph, nid)
	if node == nil { return "0.0f" }
	if node.kind == .Param {
		// MatMul handles its own param indexing; other ops use tid
		return fmt.tprintf("param_%s[tid]", node.name)
	}
	return fmt.tprintf("v%d", int(nid))
}

msl_binary_inputs :: proc(graph: ^Compute_Graph, node: ^GPU_Node, bindings: ^Binding_Info, use_matmul: bool) -> (string, string) {
	return msl_input_ref(graph, node.inputs[0], bindings, use_matmul),
	       msl_input_ref(graph, node.inputs[1], bindings, use_matmul)
}

msl_cmp_literals :: proc(etype: string) -> (string, string) {
	if etype == "int" || etype == "long" { return "1", "0" }
	return "1.0f", "0.0f"
}

msl_const_value :: proc(name: string, etype: string) -> string {
	if etype == "int" || etype == "long" { return name }
	for c in name {
		if c == '.' { return fmt.tprintf("%sf", name) }
	}
	return fmt.tprintf("%s.0f", name)
}
