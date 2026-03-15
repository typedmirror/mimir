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

	// Store outputs
	for out in graph.outputs {
		if use_matmul {
			fmt.sbprintf(&b, "    result[row * dims.N + col] = v%d;\n", int(out))
		} else {
			fmt.sbprintf(&b, "    result[tid] = v%d;\n", int(out))
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
		// Filtered at extraction — should not appear in graph
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    let v%d = %s; // softmax: unsupported\n", id, a)

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
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    let v%d = %s; // transpose: index swap at dispatch level\n", id, a)

	case .Sum, .Mean, .Max, .Min:
		a := wgsl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    let v%d = %s; // reduction: single-thread passthrough\n", id, a)

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
