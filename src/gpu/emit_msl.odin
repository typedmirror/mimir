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
) -> (string, bool) {
	use_matmul := has_matmul(graph)
	if use_matmul && !gpu_validate_2d_kernel(graph, "msl") {
		return "", false
	}
	if !use_matmul && !gpu_validate_1d_kernel(graph, "msl") {
		return "", false
	}
	use_reduction := has_reduction(graph)
	if use_reduction && !gpu_validate_reduction_bound(graph, "msl") {
		return "", false
	}

	b := strings.builder_make(0, 2048, allocator)
	etype := element_type_str(wgsl_infer_element_type(graph, type_ctx), type_ctx, .MSL)

	fmt.sbprint(&b, "#include <metal_stdlib>\nusing namespace metal;\n\n")
	if use_reduction {
		fmt.sbprintf(&b, "// dispatch requirement: exactly 1 threadgroup of %d threads\n", GPU_REDUCTION_BLOCK_BOUND)
		fmt.sbprint(&b, "// (single-group tail-guarded reduction; bound is the WebGPU-portable\n")
		fmt.sbprint(&b, "// workgroup-width minimum, kept identical across MSL/WGSL for parity)\n\n")
	}

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
		out_node := get_node(graph, out)
		is_reduce := out_node != nil && is_reduction_kind(out_node.kind)
		switch {
		case use_matmul:
			fmt.sbprintf(&b, "    result[row * N + col] = v%d;\n", int(out))
		case is_reduce:
			// D-G3v2: single write, once, to result[0] — not a per-thread
			// broadcast to result[tid] (the old bug: every thread wrote the
			// same value N-wide, and the buffer must be length 1 anyway).
			fmt.sbprintf(&b, "    if (tid == 0) result[0] = v%d;\n", int(out))
		case use_reduction:
			// Non-reduction output sharing a kernel with a reduction node
			// (e.g. softmax): dispatch is over-provisioned to the block
			// bound, so guard against writing past this output's real length.
			out_n, ok := gpu_reduction_input_len(graph, out_node)
			if !ok { out_n = GPU_REDUCTION_BLOCK_BOUND }
			fmt.sbprintf(&b, "    if (tid < %du) result[tid] = v%d;\n", out_n, int(out))
		case:
			fmt.sbprintf(&b, "    result[tid] = v%d;\n", int(out))
		}
	}

	fmt.sbprint(&b, "}\n")
	return strings.to_string(b), true
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
			// Route through msl_input_ref so this (unused-downstream, but
			// still-executed) declaration gets the same scalar/full/clamped
			// indexing as every real use site — an unguarded `param[tid]`
			// here would be an out-of-bounds read whenever a reduction
			// over-provisions tid past this param's real length.
			a := msl_input_ref(graph, node.id, bindings, use_matmul)
			fmt.sbprintf(b, "    %s v%d = %s;\n", etype, id, a)
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
		n, has_n := gpu_reduction_input_len(graph, node)
		if !has_n { n = GPU_REDUCTION_BLOCK_BOUND }
		neg_inf := msl_reduce_identity(etype, .Max)
		half := GPU_REDUCTION_BLOCK_BOUND / 2
		fmt.sbprintf(b, "    // Softmax: exp(x - max) / sum(exp(x - max)) -- tail-guarded, N=%d\n", n)
		fmt.sbprintf(b, "    threadgroup %s sm_%d[%d];\n", etype, id, GPU_REDUCTION_BLOCK_BOUND)
		fmt.sbprintf(b, "    sm_%d[tid] = (tid < %du) ? %s : %s;\n", id, n, a, neg_inf)
		fmt.sbprintf(b, "    threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    for (uint s = %d; s > 0; s >>= 1) {{\n", half)
		fmt.sbprintf(b, "        if (tid < s) sm_%d[tid] = metal::max(sm_%d[tid], sm_%d[tid + s]);\n", id, id, id)
		fmt.sbprintf(b, "        threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    }}\n")
		fmt.sbprintf(b, "    %s sm_max_%d = sm_%d[0];\n", etype, id, id)
		// D-G4v2(e): every thread must finish reading sm_%d[0] (the max)
		// before any thread starts overwriting the same shared array with
		// its exp value — without this barrier a fast thread's write races
		// a slow thread's still-pending read (data race).
		fmt.sbprintf(b, "    threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    %s sm_exp_%d = (tid < %du) ? metal::exp(%s - sm_max_%d) : (%s)0;\n", etype, id, n, a, id, etype)
		fmt.sbprintf(b, "    sm_%d[tid] = sm_exp_%d;\n", id, id)
		fmt.sbprintf(b, "    threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    for (uint s = %d; s > 0; s >>= 1) {{\n", half)
		fmt.sbprintf(b, "        if (tid < s) sm_%d[tid] += sm_%d[tid + s];\n", id, id)
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
		n, has_n := gpu_reduction_input_len(graph, node)
		if !has_n { n = GPU_REDUCTION_BLOCK_BOUND }
		ident := msl_reduce_identity(etype, .Sum)
		half := GPU_REDUCTION_BLOCK_BOUND / 2
		fmt.sbprintf(b, "    // Sum reduction -- tail-guarded, N=%d\n", n)
		fmt.sbprintf(b, "    threadgroup %s sh_%d[%d];\n", etype, id, GPU_REDUCTION_BLOCK_BOUND)
		fmt.sbprintf(b, "    sh_%d[tid] = (tid < %du) ? %s : %s;\n", id, n, a, ident)
		fmt.sbprintf(b, "    threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    for (uint s = %d; s > 0; s >>= 1) {{\n", half)
		fmt.sbprintf(b, "        if (tid < s) sh_%d[tid] += sh_%d[tid + s];\n", id, id)
		fmt.sbprintf(b, "        threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    }}\n")
		fmt.sbprintf(b, "    %s v%d = sh_%d[0];\n", etype, id, id)

	case .Mean:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		n, has_n := gpu_reduction_input_len(graph, node)
		if !has_n { n = GPU_REDUCTION_BLOCK_BOUND }
		ident := msl_reduce_identity(etype, .Mean)
		half := GPU_REDUCTION_BLOCK_BOUND / 2
		fmt.sbprintf(b, "    // Mean reduction -- tail-guarded, N=%d (divides by real N, not the block bound)\n", n)
		fmt.sbprintf(b, "    threadgroup %s sh_%d[%d];\n", etype, id, GPU_REDUCTION_BLOCK_BOUND)
		fmt.sbprintf(b, "    sh_%d[tid] = (tid < %du) ? %s : %s;\n", id, n, a, ident)
		fmt.sbprintf(b, "    threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    for (uint s = %d; s > 0; s >>= 1) {{\n", half)
		fmt.sbprintf(b, "        if (tid < s) sh_%d[tid] += sh_%d[tid + s];\n", id, id)
		fmt.sbprintf(b, "        threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    }}\n")
		fmt.sbprintf(b, "    %s v%d = sh_%d[0] / (%s)%d;\n", etype, id, id, etype, n)

	case .Max:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		n, has_n := gpu_reduction_input_len(graph, node)
		if !has_n { n = GPU_REDUCTION_BLOCK_BOUND }
		ident := msl_reduce_identity(etype, .Max)
		half := GPU_REDUCTION_BLOCK_BOUND / 2
		fmt.sbprintf(b, "    // Max reduction -- tail-guarded, N=%d\n", n)
		fmt.sbprintf(b, "    threadgroup %s sh_%d[%d];\n", etype, id, GPU_REDUCTION_BLOCK_BOUND)
		fmt.sbprintf(b, "    sh_%d[tid] = (tid < %du) ? %s : %s;\n", id, n, a, ident)
		fmt.sbprintf(b, "    threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    for (uint s = %d; s > 0; s >>= 1) {{\n", half)
		fmt.sbprintf(b, "        if (tid < s) sh_%d[tid] = metal::max(sh_%d[tid], sh_%d[tid + s]);\n", id, id, id)
		fmt.sbprintf(b, "        threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    }}\n")
		fmt.sbprintf(b, "    %s v%d = sh_%d[0];\n", etype, id, id)

	case .Min:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		n, has_n := gpu_reduction_input_len(graph, node)
		if !has_n { n = GPU_REDUCTION_BLOCK_BOUND }
		ident := msl_reduce_identity(etype, .Min)
		half := GPU_REDUCTION_BLOCK_BOUND / 2
		fmt.sbprintf(b, "    // Min reduction -- tail-guarded, N=%d\n", n)
		fmt.sbprintf(b, "    threadgroup %s sh_%d[%d];\n", etype, id, GPU_REDUCTION_BLOCK_BOUND)
		fmt.sbprintf(b, "    sh_%d[tid] = (tid < %du) ? %s : %s;\n", id, n, a, ident)
		fmt.sbprintf(b, "    threadgroup_barrier(mem_flags::mem_threadgroup);\n")
		fmt.sbprintf(b, "    for (uint s = %d; s > 0; s >>= 1) {{\n", half)
		fmt.sbprintf(b, "        if (tid < s) sh_%d[tid] = metal::min(sh_%d[tid], sh_%d[tid + s]);\n", id, id, id)
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
		if len(node.inputs) >= 2 {
			data_node := get_node(graph, node.inputs[0])
			wt_node := get_node(graph, node.inputs[1])
			d_name := fmt.tprintf("v%d", int(node.inputs[0]))
			w_name := fmt.tprintf("v%d", int(node.inputs[1]))
			if data_node != nil && data_node.kind == .Param { d_name = fmt.tprintf("param_%s", data_node.name) }
			if wt_node != nil && wt_node.kind == .Param { w_name = fmt.tprintf("param_%s", wt_node.name) }
			c_in := 3; kh := 3; kw := 3; h_in := 32; w_in := 32; c_out := 16
			if data_node != nil && data_node.output_shape != nil && len(data_node.output_shape) == 4 {
				c_in = data_node.output_shape[1]
				h_in = data_node.output_shape[2]
				w_in = data_node.output_shape[3]
			}
			if wt_node != nil && wt_node.output_shape != nil && len(wt_node.output_shape) == 4 {
				c_out = wt_node.output_shape[0]
				kh = wt_node.output_shape[2]
				kw = wt_node.output_shape[3]
			}
			h_out := h_in - kh + 1
			w_out := w_in - kw + 1
			fmt.sbprintf(b, "    // Conv2d: stride=1, padding=0\n")
			fmt.sbprintf(b, "    uint ow_%d = tid %% %d;\n", id, w_out)
			fmt.sbprintf(b, "    uint oh_%d = (tid / %d) %% %d;\n", id, w_out, h_out)
			fmt.sbprintf(b, "    uint oc_%d = (tid / %d) %% %d;\n", id, h_out * w_out, c_out)
			fmt.sbprintf(b, "    uint on_%d = tid / %d;\n", id, c_out * h_out * w_out)
			fmt.sbprintf(b, "    %s v%d = 0;\n", etype, id)
			fmt.sbprintf(b, "    for (uint ci = 0; ci < %d; ci++) {{\n", c_in)
			fmt.sbprintf(b, "      for (uint ky = 0; ky < %d; ky++) {{\n", kh)
			fmt.sbprintf(b, "        for (uint kx = 0; kx < %d; kx++) {{\n", kw)
			fmt.sbprintf(b, "          uint di = on_%d * %d + ci * %d + (oh_%d + ky) * %d + ow_%d + kx;\n",
				id, c_in * h_in * w_in, h_in * w_in, id, w_in, id)
			fmt.sbprintf(b, "          uint wi = oc_%d * %d + ci * %d + ky * %d + kx;\n",
				id, c_in * kh * kw, kh * kw, kw)
			fmt.sbprintf(b, "          v%d += %s[di] * %s[wi];\n", id, d_name, w_name)
			fmt.sbprintf(b, "        }}\n")
			fmt.sbprintf(b, "      }}\n")
			fmt.sbprintf(b, "    }}\n")
		} else {
			fmt.sbprintf(b, "    %s v%d = 0; // conv2d: missing inputs\n", etype, id)
		}
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

// Per-op identity element for the tail-guard fill (clauses d/e, D-G3v2):
// lanes at tid >= N must contribute nothing to the reduction.
msl_reduce_identity :: proc(etype: string, kind: GPU_Op_Kind) -> string {
	is_int := etype == "int" || etype == "long"
	#partial switch kind {
	case .Sum, .Mean:
		return "0" if is_int else "0.0f"
	case .Max:
		return "(-2147483647 - 1)" if is_int else "-INFINITY"
	case .Min:
		return "2147483647" if is_int else "INFINITY"
	}
	return "0"
}

msl_input_ref :: proc(graph: ^Compute_Graph, nid: GPU_Node_ID, bindings: ^Binding_Info, use_matmul: bool) -> string {
	node := get_node(graph, nid)
	if node == nil { return "0.0f" }
	if node.kind == .Param {
		// MatMul handles its own param indexing; other ops index by thread.
		if !use_matmul {
			// Clause (c): classify against the kernel's real dispatch length —
			// gpu_validate_1d_kernel already refused anything Unsupported.
			n, ok := gpu_kernel_ref_len_1d(graph)
			if ok && gpu_param_bcast_mode_1d(node.output_shape, n) == .Scalar {
				return fmt.tprintf("param_%s[0]", node.name)
			}
			if ok && n > 0 && has_reduction(graph) {
				// Reduction/softmax kernels dispatch GPU_REDUCTION_BLOCK_BOUND
				// threads regardless of this param's real length (tail-guarded
				// single group) — clamp the READ index so over-provisioned
				// threads stay in-bounds. The reduction's own shared-memory
				// load applies the identity-element mask for correctness;
				// this clamp is a memory-safety guard only.
				return fmt.tprintf("param_%s[metal::min(tid, (uint)%d - 1)]", node.name, n)
			}
			return fmt.tprintf("param_%s[tid]", node.name)
		}
		// 2D (matmul) mode: no linear `tid` is declared — index by the
		// broadcast-aware row/col that IS declared. gpu_validate_2d_kernel
		// already refused emission for any pattern this can't classify.
		m, n, ok := gpu_kernel_ref_shape(graph)
		if ok {
			switch gpu_param_bcast_mode(node.output_shape, m, n) {
			case .Full:   return fmt.tprintf("param_%s[row * N + col]", node.name)
			case .Col:    return fmt.tprintf("param_%s[col]", node.name)
			case .Row:    return fmt.tprintf("param_%s[row]", node.name)
			case .Scalar: return fmt.tprintf("param_%s[0]", node.name)
			case .Unsupported:
			}
		}
		return fmt.tprintf("param_%s[row * N + col]", node.name)
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
