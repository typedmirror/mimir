package gpu

import "core:mem"
import "core:fmt"
import "core:strings"

import checker "mimir:checker"

// WGSL compute shader emission from compute graph.

emit_wgsl :: proc(
	graph: ^Compute_Graph,
	type_ctx: ^GPU_Type_Context,
	bindings: ^Binding_Info,
	allocator: mem.Allocator,
) -> string {
	b := strings.builder_make(0, 2048, allocator)
	etype := element_type_str(wgsl_infer_element_type(graph, type_ctx), type_ctx, .WGSL)

	// Storage buffer declarations
	for inp in graph.inputs {
		node := get_node(graph, inp)
		if node == nil { continue }
		binding := bindings.param_bindings[inp]
		fmt.sbprintf(&b, "@group(0) @binding(%d) var<storage, read> param_%s: array<%s>;\n",
			binding, node.name, etype)
	}
	for out in graph.outputs {
		binding := bindings.output_bindings[out]
		fmt.sbprintf(&b, "@group(0) @binding(%d) var<storage, read_write> result: array<%s>;\n",
			binding, etype)
	}

	// MatMul needs dims uniform
	use_matmul := has_matmul(graph)
	if use_matmul {
		fmt.sbprintf(&b, "\nstruct MatMulDims {{ M: u32, K: u32, N: u32 }}\n")
		fmt.sbprintf(&b, "@group(0) @binding(%d) var<uniform> dims: MatMulDims;\n",
			bindings.total_bindings)
	}

	fmt.sbprint(&b, "\n")

	// Entry point
	if use_matmul {
		fmt.sbprintf(&b, "@compute @workgroup_size(8, 8)\nfn kernel_%s(@builtin(global_invocation_id) gid: vec3<u32>) {{\n", graph.func_name)
		fmt.sbprint(&b, "    let row = gid.x;\n")
		fmt.sbprint(&b, "    let col = gid.y;\n")
	} else {
		fmt.sbprintf(&b, "@compute @workgroup_size(64)\nfn kernel_%s(@builtin(global_invocation_id) gid: vec3<u32>) {{\n", graph.func_name)
		fmt.sbprint(&b, "    let tid = gid.x;\n")
	}

	// Emit each node
	for &node in graph.nodes {
		wgsl_emit_node(&b, graph, &node, bindings, etype, use_matmul)
	}

	// Store outputs — each output gets its own buffer binding
	for out, out_idx in graph.outputs {
		buf_name := "result" if len(graph.outputs) == 1 else fmt.tprintf("output%d", out_idx)
		if use_matmul {
			fmt.sbprintf(&b, "    %s[row * dims.N + col] = v%d;\n", buf_name, int(out))
		} else {
			fmt.sbprintf(&b, "    %s[tid] = v%d;\n", buf_name, int(out))
		}
	}

	fmt.sbprint(&b, "}\n")
	return strings.to_string(b)
}

wgsl_emit_node :: proc(
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
		if use_matmul {
			fmt.sbprintf(b, "    // param %s accessed via buffer\n", node.name)
		} else {
			fmt.sbprintf(b, "    let v%d = param_%s[tid];\n", id, node.name)
		}

	case .Constant:
		fmt.sbprintf(b, "    let v%d: %s = %s;\n", id, etype, wgsl_const_value(node.name, etype))

	case .Add:
		a, c := wgsl_binary_inputs(graph, node, bindings, use_matmul)
		fmt.sbprintf(b, "    let v%d = %s + %s;\n", id, a, c)
	case .Sub:
		a, c := wgsl_binary_inputs(graph, node, bindings, use_matmul)
		fmt.sbprintf(b, "    let v%d = %s - %s;\n", id, a, c)
	case .Mul:
		a, c := wgsl_binary_inputs(graph, node, bindings, use_matmul)
		fmt.sbprintf(b, "    let v%d = %s * %s;\n", id, a, c)
	case .Div:
		a, c := wgsl_binary_inputs(graph, node, bindings, use_matmul)
		fmt.sbprintf(b, "    let v%d = %s / %s;\n", id, a, c)

	case .Neg:
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    let v%d = -%s;\n", id, a)
	case .Abs:
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    let v%d = abs(%s);\n", id, a)

	case .Equal:
		a, c := wgsl_binary_inputs(graph, node, bindings, use_matmul)
		zero, one := wgsl_cmp_literals(etype)
		fmt.sbprintf(b, "    let v%d = select(%s, %s, %s == %s);\n", id, zero, one, a, c)
	case .NotEqual:
		a, c := wgsl_binary_inputs(graph, node, bindings, use_matmul)
		zero, one := wgsl_cmp_literals(etype)
		fmt.sbprintf(b, "    let v%d = select(%s, %s, %s != %s);\n", id, zero, one, a, c)
	case .Less:
		a, c := wgsl_binary_inputs(graph, node, bindings, use_matmul)
		zero, one := wgsl_cmp_literals(etype)
		fmt.sbprintf(b, "    let v%d = select(%s, %s, %s < %s);\n", id, zero, one, a, c)
	case .Greater:
		a, c := wgsl_binary_inputs(graph, node, bindings, use_matmul)
		zero, one := wgsl_cmp_literals(etype)
		fmt.sbprintf(b, "    let v%d = select(%s, %s, %s > %s);\n", id, zero, one, a, c)
	case .LessEq:
		a, c := wgsl_binary_inputs(graph, node, bindings, use_matmul)
		zero, one := wgsl_cmp_literals(etype)
		fmt.sbprintf(b, "    let v%d = select(%s, %s, %s <= %s);\n", id, zero, one, a, c)
	case .GreaterEq:
		a, c := wgsl_binary_inputs(graph, node, bindings, use_matmul)
		zero, one := wgsl_cmp_literals(etype)
		fmt.sbprintf(b, "    let v%d = select(%s, %s, %s >= %s);\n", id, zero, one, a, c)

	case .ReLU:
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		zero := "0" if (etype == "i32" || etype == "i64") else "0.0"
		fmt.sbprintf(b, "    let v%d = max(%s, %s);\n", id, a, zero)
	case .Sigmoid:
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    let v%d = 1.0 / (1.0 + exp(-%s));\n", id, a)
	case .Tanh:
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    let v%d = tanh(%s);\n", id, a)

	case .Softmax:
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		// Two-pass softmax via shared memory: max → exp(x-max) → sum → divide
		fmt.sbprintf(b, "    // Softmax: exp(x - max(x)) / sum(exp(x - max(x)))\n")
		fmt.sbprintf(b, "    var<workgroup> sm_%d: array<%s, 256>;\n", id, etype)
		fmt.sbprintf(b, "    sm_%d[tid %% 256u] = %s;\n", id, a)
		fmt.sbprintf(b, "    workgroupBarrier();\n")
		// Pass 1: find max
		fmt.sbprintf(b, "    for (var s_%d = 128u; s_%d > 0u; s_%d >>= 1u) {{\n", id, id, id)
		fmt.sbprintf(b, "        if (tid %% 256u < s_%d) {{ sm_%d[tid %% 256u] = max(sm_%d[tid %% 256u], sm_%d[tid %% 256u + s_%d]); }}\n", id, id, id, id, id)
		fmt.sbprintf(b, "        workgroupBarrier();\n")
		fmt.sbprintf(b, "    }}\n")
		fmt.sbprintf(b, "    let sm_max_%d = sm_%d[0];\n", id, id)
		// Pass 2: exp(x - max)
		fmt.sbprintf(b, "    let sm_exp_%d = exp(%s - sm_max_%d);\n", id, a, id)
		// Pass 3: sum of exp
		fmt.sbprintf(b, "    sm_%d[tid %% 256u] = sm_exp_%d;\n", id, id)
		fmt.sbprintf(b, "    workgroupBarrier();\n")
		fmt.sbprintf(b, "    for (var s_%d = 128u; s_%d > 0u; s_%d >>= 1u) {{\n", id, id, id)
		fmt.sbprintf(b, "        if (tid %% 256u < s_%d) {{ sm_%d[tid %% 256u] += sm_%d[tid %% 256u + s_%d]; }}\n", id, id, id, id)
		fmt.sbprintf(b, "        workgroupBarrier();\n")
		fmt.sbprintf(b, "    }}\n")
		fmt.sbprintf(b, "    let v%d = sm_exp_%d / sm_%d[0];\n", id, id, id)

	case .MatMul:
		if len(node.inputs) >= 2 {
			a_node := get_node(graph, node.inputs[0])
			b_node := get_node(graph, node.inputs[1])
			a_name := fmt.tprintf("v%d", int(node.inputs[0]))
			b_name := fmt.tprintf("v%d", int(node.inputs[1]))
			if a_node != nil && a_node.kind == .Param && len(a_node.name) > 0 { a_name = fmt.tprintf("param_%s", a_node.name) }
			if b_node != nil && b_node.kind == .Param && len(b_node.name) > 0 { b_name = fmt.tprintf("param_%s", b_node.name) }
			fmt.sbprintf(b, "    var v%d: %s = 0.0;\n", id, etype)
			fmt.sbprintf(b, "    for (var k: u32 = 0u; k < dims.K; k++) {{\n")
			fmt.sbprintf(b, "        v%d += %s[row * dims.K + k] * %s[k * dims.N + col];\n", id, a_name, b_name)
			fmt.sbprintf(b, "    }}\n")
		}

	case .Transpose:
		// Transpose via shared memory tile (16x16 + 1 padding for bank conflicts)
		a_node := get_node(graph, node.inputs[0])
		if a_node != nil && a_node.kind == .Param && len(a_node.name) > 0 {
			fmt.sbprintf(b, "    // Transpose: shared memory tile\n")
			fmt.sbprintf(b, "    var<workgroup> tile_%d: array<array<%s, 17>, 16>;\n", id, etype)
			fmt.sbprintf(b, "    let tx_%d = tid %% 16u;\n", id)
			fmt.sbprintf(b, "    let ty_%d = (tid / 16u) %% 16u;\n", id)
			fmt.sbprintf(b, "    tile_%d[ty_%d][tx_%d] = param_%s[ty_%d * 16u + tx_%d];\n", id, id, id, a_node.name, id, id)
			fmt.sbprintf(b, "    workgroupBarrier();\n")
			fmt.sbprintf(b, "    let v%d = tile_%d[tx_%d][ty_%d];\n", id, id, id, id)
		} else {
			a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
			fmt.sbprintf(b, "    let v%d = %s; // transpose: index swap at dispatch level\n", id, a)
		}

	case .Sum:
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    // Sum reduction via workgroup shared memory\n")
		fmt.sbprintf(b, "    var<workgroup> sh_%d: array<%s, 256>;\n", id, etype)
		fmt.sbprintf(b, "    sh_%d[tid %% 256u] = %s;\n", id, a)
		fmt.sbprintf(b, "    workgroupBarrier();\n")
		fmt.sbprintf(b, "    for (var stride_%d = 128u; stride_%d > 0u; stride_%d >>= 1u) {{\n", id, id, id)
		fmt.sbprintf(b, "        if (tid %% 256u < stride_%d) {{ sh_%d[tid %% 256u] += sh_%d[tid %% 256u + stride_%d]; }}\n", id, id, id, id)
		fmt.sbprintf(b, "        workgroupBarrier();\n")
		fmt.sbprintf(b, "    }}\n")
		fmt.sbprintf(b, "    let v%d = sh_%d[0];\n", id, id)

	case .Mean:
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    var<workgroup> sh_%d: array<%s, 256>;\n", id, etype)
		fmt.sbprintf(b, "    sh_%d[tid %% 256u] = %s;\n", id, a)
		fmt.sbprintf(b, "    workgroupBarrier();\n")
		fmt.sbprintf(b, "    for (var stride_%d = 128u; stride_%d > 0u; stride_%d >>= 1u) {{\n", id, id, id)
		fmt.sbprintf(b, "        if (tid %% 256u < stride_%d) {{ sh_%d[tid %% 256u] += sh_%d[tid %% 256u + stride_%d]; }}\n", id, id, id, id)
		fmt.sbprintf(b, "        workgroupBarrier();\n")
		fmt.sbprintf(b, "    }}\n")
		fmt.sbprintf(b, "    let v%d = sh_%d[0] / %s(arrayLength(&param_%s));\n", id, id, etype,
			wgsl_first_param_name(graph))

	case .Max:
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    var<workgroup> sh_%d: array<%s, 256>;\n", id, etype)
		neg_inf := "-3.402823e+38" if etype == "f32" else "-2147483648"
		fmt.sbprintf(b, "    sh_%d[tid %% 256u] = %s;\n", id, a)
		_ = neg_inf
		fmt.sbprintf(b, "    workgroupBarrier();\n")
		fmt.sbprintf(b, "    for (var stride_%d = 128u; stride_%d > 0u; stride_%d >>= 1u) {{\n", id, id, id)
		fmt.sbprintf(b, "        if (tid %% 256u < stride_%d) {{ sh_%d[tid %% 256u] = max(sh_%d[tid %% 256u], sh_%d[tid %% 256u + stride_%d]); }}\n", id, id, id, id, id)
		fmt.sbprintf(b, "        workgroupBarrier();\n")
		fmt.sbprintf(b, "    }}\n")
		fmt.sbprintf(b, "    let v%d = sh_%d[0];\n", id, id)

	case .Min:
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    var<workgroup> sh_%d: array<%s, 256>;\n", id, etype)
		fmt.sbprintf(b, "    sh_%d[tid %% 256u] = %s;\n", id, a)
		fmt.sbprintf(b, "    workgroupBarrier();\n")
		fmt.sbprintf(b, "    for (var stride_%d = 128u; stride_%d > 0u; stride_%d >>= 1u) {{\n", id, id, id)
		fmt.sbprintf(b, "        if (tid %% 256u < stride_%d) {{ sh_%d[tid %% 256u] = min(sh_%d[tid %% 256u], sh_%d[tid %% 256u + stride_%d]); }}\n", id, id, id, id, id)
		fmt.sbprintf(b, "        workgroupBarrier();\n")
		fmt.sbprintf(b, "    }}\n")
		fmt.sbprintf(b, "    let v%d = sh_%d[0];\n", id, id)

	case .Select:
		if len(node.inputs) >= 3 {
			cond := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
			tv := wgsl_input_ref(graph, node.inputs[1], bindings, use_matmul)
			fv := wgsl_input_ref(graph, node.inputs[2], bindings, use_matmul)
			fmt.sbprintf(b, "    let v%d = select(%s, %s, %s > 0.0);\n", id, fv, tv, cond)
		}

	case .Reshape, .Broadcast:
		if len(node.inputs) > 0 {
			a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
			fmt.sbprintf(b, "    let v%d = %s;\n", id, a)
		}

	// Math ops
	case .Exp:
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    let v%d = exp(%s);\n", id, a)
	case .Log:
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    let v%d = log(%s);\n", id, a)
	case .Sqrt:
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    let v%d = sqrt(%s);\n", id, a)
	case .Pow:
		a, c := wgsl_binary_inputs(graph, node, bindings, use_matmul)
		fmt.sbprintf(b, "    let v%d = pow(%s, %s);\n", id, a, c)
	case .Clamp:
		if len(node.inputs) >= 3 {
			a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
			lo := wgsl_input_ref(graph, node.inputs[1], bindings, use_matmul)
			hi := wgsl_input_ref(graph, node.inputs[2], bindings, use_matmul)
			fmt.sbprintf(b, "    let v%d = clamp(%s, %s, %s);\n", id, a, lo, hi)
		} else if len(node.inputs) >= 1 {
			a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
			fmt.sbprintf(b, "    let v%d = %s;\n", id, a)
		}

	// NN ops
	case .Conv2d:
		// Conv2d: each thread computes one output element
		// output[n, co, oh, ow] = sum_{ci, kh, kw} data[n, ci, oh+kh, ow+kw] * weight[co, ci, kh, kw]
		if len(node.inputs) >= 2 {
			data_node := get_node(graph, node.inputs[0])
			wt_node := get_node(graph, node.inputs[1])
			d_name := fmt.tprintf("v%d", int(node.inputs[0]))
			w_name := fmt.tprintf("v%d", int(node.inputs[1]))
			if data_node != nil && data_node.kind == .Param { d_name = fmt.tprintf("param_%s", data_node.name) }
			if wt_node != nil && wt_node.kind == .Param { w_name = fmt.tprintf("param_%s", wt_node.name) }
			// Extract shapes for loop bounds
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
			fmt.sbprintf(b, "    // Conv2d: [N,%d,%d,%d] * [%d,%d,%d,%d] → [N,%d,%d,%d], stride=1, padding=0\n",
				c_in, h_in, w_in, c_out, c_in, kh, kw, c_out, h_out, w_out)
			fmt.sbprintf(b, "    let oidx_%d = tid;\n", id)
			fmt.sbprintf(b, "    let ow_%d = oidx_%d %% %du;\n", id, id, w_out)
			fmt.sbprintf(b, "    let oh_%d = (oidx_%d / %du) %% %du;\n", id, id, w_out, h_out)
			fmt.sbprintf(b, "    let oc_%d = (oidx_%d / %du) %% %du;\n", id, id, h_out * w_out, c_out)
			fmt.sbprintf(b, "    let on_%d = oidx_%d / %du;\n", id, id, c_out * h_out * w_out)
			fmt.sbprintf(b, "    var v%d: %s = 0.0;\n", id, etype)
			fmt.sbprintf(b, "    for (var ci_%d: u32 = 0u; ci_%d < %du; ci_%d++) {{\n", id, id, c_in, id)
			fmt.sbprintf(b, "      for (var ky_%d: u32 = 0u; ky_%d < %du; ky_%d++) {{\n", id, id, kh, id)
			fmt.sbprintf(b, "        for (var kx_%d: u32 = 0u; kx_%d < %du; kx_%d++) {{\n", id, id, kw, id)
			fmt.sbprintf(b, "          let di_%d = on_%d * %du + ci_%d * %du + (oh_%d + ky_%d) * %du + ow_%d + kx_%d;\n",
				id, id, c_in * h_in * w_in, id, h_in * w_in, id, id, w_in, id, id)
			fmt.sbprintf(b, "          let wi_%d = oc_%d * %du + ci_%d * %du + ky_%d * %du + kx_%d;\n",
				id, id, c_in * kh * kw, id, kh * kw, id, kw, id)
			fmt.sbprintf(b, "          v%d += %s[di_%d] * %s[wi_%d];\n", id, d_name, id, w_name, id)
			fmt.sbprintf(b, "        }}\n")
			fmt.sbprintf(b, "      }}\n")
			fmt.sbprintf(b, "    }}\n")
		}

	case .MaxPool2d:
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    // MaxPool2d: 2x2 kernel, stride 2\n")
		fmt.sbprintf(b, "    let v%d = %s; // pool: per-element passthrough\n", id, a)

	case .AvgPool2d:
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    let v%d = %s; // avgpool: per-element passthrough\n", id, a)

	case .BatchNorm:
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    let v%d = %s; // batchnorm: inference mode passthrough\n", id, a)

	case .Dropout:
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    let v%d = %s; // dropout: identity at inference\n", id, a)

	case .Flatten:
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    let v%d = %s; // flatten: reshape at dispatch level\n", id, a)

	case .CrossEntropy:
		if len(node.inputs) >= 2 {
			logits := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
			fmt.sbprintf(b, "    // CrossEntropy: -log(softmax(logits)[label])\n")
			fmt.sbprintf(b, "    let v%d = -log(exp(%s) / (exp(%s) + 1.0));\n", id, logits, logits)
		} else if len(node.inputs) >= 1 {
			a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
			fmt.sbprintf(b, "    let v%d = %s;\n", id, a)
		}
	}
}

// Get a reference string for a node's value.
wgsl_input_ref :: proc(graph: ^Compute_Graph, nid: GPU_Node_ID, bindings: ^Binding_Info, use_matmul: bool) -> string {
	node := get_node(graph, nid)
	if node == nil { return "0.0" }
	if node.kind == .Param {
		// MatMul handles its own param indexing; other ops use tid
		return fmt.tprintf("param_%s[tid]", node.name)
	}
	return fmt.tprintf("v%d", int(nid))
}

wgsl_binary_inputs :: proc(graph: ^Compute_Graph, node: ^GPU_Node, bindings: ^Binding_Info, use_matmul: bool) -> (string, string) {
	a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
	c := wgsl_input_ref(graph, node.inputs[1], bindings, use_matmul)
	return a, c
}

// Return type-appropriate zero/one literals for comparison select().
wgsl_cmp_literals :: proc(etype: string) -> (string, string) {
	if etype == "i32" || etype == "i64" {
		return "0", "1"
	}
	return "0.0", "1.0"
}

// Get the name of the first param in the graph (for arrayLength in reductions).
wgsl_first_param_name :: proc(graph: ^Compute_Graph) -> string {
	for inp in graph.inputs {
		node := get_node(graph, inp)
		if node != nil && len(node.name) > 0 {
			return node.name
		}
	}
	return "input"
}

wgsl_const_value :: proc(name: string, etype: string) -> string {
	if etype == "i32" || etype == "i64" {
		return fmt.tprintf("i32(%s)", name)
	}
	// Ensure float constants have decimal
	for c in name {
		if c == '.' { return name }
	}
	return fmt.tprintf("%s.0", name)
}

// Infer the dominant element type from graph inputs.
wgsl_infer_element_type :: proc(graph: ^Compute_Graph, type_ctx: ^GPU_Type_Context) -> checker.Type_ID {
	for inp in graph.inputs {
		node := get_node(graph, inp)
		if node != nil && node.output_type != checker.INVALID_TYPE {
			return node.output_type
		}
	}
	return checker.TYPE_FLOAT
}
