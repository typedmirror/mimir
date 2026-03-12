package gpu

import "core:mem"
import "core:fmt"
import "core:strings"

import checker "mimir:checker"

// Shared emission framework for GPU backends.

Emit_Backend :: enum {
	WGSL,
	MSL,
	SPIRV,
	PTX,
}

Binding_Info :: struct {
	param_bindings:  map[GPU_Node_ID]int,
	output_bindings: map[GPU_Node_ID]int,
	total_bindings:  int,
}

// Assign buffer bindings: params 0..N-1, outputs N..N+M-1.
assign_bindings :: proc(graph: ^Compute_Graph, allocator: mem.Allocator) -> Binding_Info {
	info := Binding_Info{
		param_bindings  = make(map[GPU_Node_ID]int, len(graph.inputs), allocator),
		output_bindings = make(map[GPU_Node_ID]int, len(graph.outputs), allocator),
	}
	idx := 0
	for inp in graph.inputs {
		info.param_bindings[inp] = idx
		idx += 1
	}
	for out in graph.outputs {
		info.output_bindings[out] = idx
		idx += 1
	}
	info.total_bindings = idx
	return info
}

// Map a checker type to the element type name for a given backend.
element_type_str :: proc(type_id: checker.Type_ID, reg: ^checker.Type_Registry, backend: Emit_Backend) -> string {
	// Resolve tensor element type
	actual := type_id
	t := checker.get_type(reg, type_id)
	#partial switch info in t.info {
	case checker.Tensor_Type:
		actual = info.element_type
	}

	is_int := actual == checker.TYPE_INT
	a := checker.get_type(reg, actual)
	#partial switch p in a.info {
	case checker.Primitive_Type:
		if p.kind == .Int {
			is_int = true
		}
	}

	switch backend {
	case .WGSL:
		return "i32" if is_int else "f32"
	case .MSL:
		return "int" if is_int else "float"
	case .SPIRV:
		return "" // SPIR-V uses type IDs, not strings
	case .PTX:
		return ".s32" if is_int else ".f32"
	}
	return "f32"
}

// Check if a graph has any matmul operations (needs 2D dispatch).
has_matmul :: proc(graph: ^Compute_Graph) -> bool {
	for node in graph.nodes {
		if node.kind == .MatMul { return true }
	}
	return false
}

// Check if a graph has reduction ops.
has_reduction :: proc(graph: ^Compute_Graph) -> bool {
	for node in graph.nodes {
		#partial switch node.kind {
		case .Sum, .Mean, .Max, .Min, .Softmax:
			return true
		case:
		}
	}
	return false
}

// Top-level emit dispatcher.
emit_kernel :: proc(
	graph: ^Compute_Graph,
	type_ctx: ^GPU_Type_Context,
	backend: Emit_Backend,
	allocator: mem.Allocator,
) -> (data: []u8, is_binary: bool) {
	bindings := assign_bindings(graph, allocator)

	switch backend {
	case .WGSL:
		s := emit_wgsl(graph, type_ctx, &bindings, allocator)
		return transmute([]u8)s, false
	case .MSL:
		s := emit_msl(graph, type_ctx, &bindings, allocator)
		return transmute([]u8)s, false
	case .SPIRV:
		return emit_spirv(graph, type_ctx, &bindings, allocator), true
	case .PTX:
		s := emit_ptx(graph, type_ctx, &bindings, allocator)
		return transmute([]u8)s, false
	}
	return nil, false
}

// Backend file extension.
backend_extension :: proc(backend: Emit_Backend) -> string {
	switch backend {
	case .WGSL:  return "wgsl"
	case .MSL:   return "metal"
	case .SPIRV: return "spv"
	case .PTX:   return "ptx"
	}
	return "txt"
}

// Parse backend name from string.
parse_backend :: proc(name: string) -> (Emit_Backend, bool) {
	switch name {
	case "wgsl":           return .WGSL, true
	case "msl", "metal":   return .MSL, true
	case "spirv", "spv", "vulkan": return .SPIRV, true
	case "ptx", "cuda":    return .PTX, true
	}
	return .WGSL, false
}
