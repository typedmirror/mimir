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
	etype := element_type_str(wgsl_infer_element_type(graph, type_ctx), type_ctx.reg, .MSL)
	use_matmul := has_matmul(graph)

	fmt.sbprint(&b, "#include <metal_stdlib>\nusing namespace metal;\n\n")

	// Kernel signature
	fmt.sbprintf(&b, "kernel void kernel_%s(\n", graph.func_name)

	// Parameter buffers
	for inp in graph.inputs {
		node := get_node(graph, inp)
		if node == nil { continue }
		binding := bindings.param_bindings[inp]
		fmt.sbprintf(&b, "    device const %s* param_%s [[buffer(%d)]],\n",
			etype, node.name, binding)
	}
	// Output buffer
	for out in graph.outputs {
		binding := bindings.output_bindings[out]
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
		fmt.sbprintf(b, "    %s v%d = (%s == %s) ? 1.0f : 0.0f;\n", etype, id, a, c)
	case .Less:
		a, c := msl_binary_inputs(graph, node, bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = (%s < %s) ? 1.0f : 0.0f;\n", etype, id, a, c)
	case .Greater:
		a, c := msl_binary_inputs(graph, node, bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = (%s > %s) ? 1.0f : 0.0f;\n", etype, id, a, c)
	case .LessEq:
		a, c := msl_binary_inputs(graph, node, bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = (%s <= %s) ? 1.0f : 0.0f;\n", etype, id, a, c)
	case .GreaterEq:
		a, c := msl_binary_inputs(graph, node, bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = (%s >= %s) ? 1.0f : 0.0f;\n", etype, id, a, c)

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
		fmt.sbprintf(b, "    %s v%d = metal::exp(%s);\n", etype, id, a)

	case .MatMul:
		if len(node.inputs) >= 2 {
			a_node := get_node(graph, node.inputs[0])
			b_node := get_node(graph, node.inputs[1])
			a_name := "param_a"
			b_name := "param_b"
			if a_node != nil && len(a_node.name) > 0 { a_name = fmt.tprintf("param_%s", a_node.name) }
			if b_node != nil && len(b_node.name) > 0 { b_name = fmt.tprintf("param_%s", b_node.name) }
			fmt.sbprintf(b, "    %s v%d = 0;\n", etype, id)
			fmt.sbprintf(b, "    for (uint k = 0; k < K; k++) {{\n")
			fmt.sbprintf(b, "        v%d += %s[row * K + k] * %s[k * N + col];\n", id, a_name, b_name)
			fmt.sbprintf(b, "    }}\n")
		}

	case .Transpose:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = %s; // transpose\n", etype, id, a)

	case .Sum, .Mean, .Max, .Min:
		a := msl_input_ref(graph, node.inputs[0], bindings, use_matmul)
		fmt.sbprintf(b, "    %s v%d = %s; // reduction passthrough\n", etype, id, a)

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
	}
}

msl_input_ref :: proc(graph: ^Compute_Graph, nid: GPU_Node_ID, bindings: ^Binding_Info, use_matmul: bool) -> string {
	node := get_node(graph, nid)
	if node == nil { return "0.0f" }
	if node.kind == .Param {
		if use_matmul {
			return fmt.tprintf("param_%s[row * K + k]", node.name)
		}
		return fmt.tprintf("param_%s[tid]", node.name)
	}
	return fmt.tprintf("v%d", int(nid))
}

msl_binary_inputs :: proc(graph: ^Compute_Graph, node: ^GPU_Node, bindings: ^Binding_Info, use_matmul: bool) -> (string, string) {
	return msl_input_ref(graph, node.inputs[0], bindings, use_matmul),
	       msl_input_ref(graph, node.inputs[1], bindings, use_matmul)
}

msl_const_value :: proc(name: string, etype: string) -> string {
	if etype == "int" { return name }
	for c in name {
		if c == '.' { return fmt.tprintf("%sf", name) }
	}
	return fmt.tprintf("%s.0f", name)
}
