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
// Uses GPU_Type_Context to distinguish precision types (f16/f32/f64, i32/i64).
element_type_str :: proc(type_id: checker.Type_ID, type_ctx: ^GPU_Type_Context, backend: Emit_Backend) -> string {
	// Resolve tensor element type
	actual := type_id
	t := checker.get_type(type_ctx.reg, type_id)
	#partial switch info in t.info {
	case checker.Tensor_Type:
		actual = info.element_type
	}

	// Check GPU precision types by ID equality (these are distinct even though Primitive_Kind is same)
	switch backend {
	case .WGSL:
		if actual == type_ctx.float16_id || actual == type_ctx.bfloat16_id { return "f16" }
		if actual == type_ctx.float32_id || actual == checker.TYPE_FLOAT    { return "f32" }
		if actual == type_ctx.int64_id                                     { return "i64" }
		if actual == type_ctx.int32_id || actual == checker.TYPE_INT || actual == checker.TYPE_BOOL { return "i32" }
	case .MSL:
		if actual == type_ctx.float16_id || actual == type_ctx.bfloat16_id { return "half" }
		if actual == type_ctx.float32_id || actual == checker.TYPE_FLOAT    { return "float" }
		if actual == type_ctx.int64_id                                     { return "long" }
		if actual == type_ctx.int32_id || actual == checker.TYPE_INT || actual == checker.TYPE_BOOL { return "int" }
	case .PTX:
		if actual == type_ctx.float16_id || actual == type_ctx.bfloat16_id { return ".f16" }
		if actual == type_ctx.float32_id || actual == checker.TYPE_FLOAT    { return ".f32" }
		if actual == type_ctx.int64_id                                     { return ".s64" }
		if actual == type_ctx.int32_id || actual == checker.TYPE_INT || actual == checker.TYPE_BOOL { return ".s32" }
	case .SPIRV:
		return "" // SPIR-V uses type IDs, not strings
	}

	// Fallback: inspect Primitive_Kind
	a := checker.get_type(type_ctx.reg, actual)
	#partial switch p in a.info {
	case checker.Primitive_Type:
		if p.kind == .Int {
			switch backend {
			case .WGSL: return "i32"
			case .MSL:  return "int"
			case .PTX:  return ".s32"
			case .SPIRV: return ""
			}
		}
	}

	switch backend {
	case .WGSL: return "f32"
	case .MSL:  return "float"
	case .PTX:  return ".f32"
	case .SPIRV: return ""
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

// Check if a graph has Conv2d ops (needs 2D dispatch).
has_conv2d :: proc(graph: ^Compute_Graph) -> bool {
	for node in graph.nodes {
		if node.kind == .Conv2d { return true }
	}
	return false
}

// Check if a graph has reduction ops.
has_reduction :: proc(graph: ^Compute_Graph) -> bool {
	for node in graph.nodes {
		#partial switch node.kind {
		case .Sum, .Mean, .Max, .Min, .Softmax, .CrossEntropy:
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
