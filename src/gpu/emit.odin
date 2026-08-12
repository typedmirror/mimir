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

// ==================== 2D-kernel dispatch validation ====================
//
// MSL/WGSL emit two mutually-exclusive per-thread indexing modes for a single
// (unfused) kernel: 1D elementwise (`tid`, declared only in that mode) and 2D
// matmul (`row`/`col`/`gid`, declared only in that mode). A graph that mixes
// matmul with a linear-thread-group construct (reduction ops, or Transpose's
// shared-memory tile path) in ONE unfused kernel cannot be correctly indexed
// under the current single-dispatch design — nor can a Param whose shape
// doesn't broadcast cleanly against the kernel's 2D output shape, nor two
// MatMuls with different (M,K,N) sharing one `dims` uniform. Rather than
// silently emit code referencing an undeclared identifier (MSL/WGSL) or
// silently mis-index a buffer, refuse loudly (project invariant: no silent
// anything) — the caller must use `--fuse` to split into separate kernels.

// Reference 2D shape [M, N] for row/col broadcast indexing in a matmul-mode
// kernel — the graph's final output shape, which is what `result[row*N+col]`
// already assumes.
gpu_kernel_ref_shape :: proc(graph: ^Compute_Graph) -> (m: int, n: int, ok: bool) {
	if len(graph.outputs) == 0 { return 0, 0, false }
	out := get_node(graph, graph.outputs[0])
	if out == nil || out.output_shape == nil || len(out.output_shape) != 2 { return 0, 0, false }
	return out.output_shape[0], out.output_shape[1], true
}

Param_Bcast_Mode :: enum {
	Full,        // 2D (M,N) — same shape as kernel output, index [row*N+col]
	Col,         // 1D (N,) or 2D (1,N) — broadcast down rows, index [col]
	Row,         // 2D (M,1) — broadcast across columns, index [row]
	Scalar,      // 1D (1,) or 2D (1,1) — index [0]
	Unsupported, // does not broadcast cleanly against [M,N] under numpy rules
}

gpu_param_bcast_mode :: proc(shape: []int, m: int, n: int) -> Param_Bcast_Mode {
	if shape == nil || len(shape) == 0 { return .Scalar }
	switch len(shape) {
	case 1:
		d := shape[0]
		if d == n { return .Col }
		if d == 1 { return .Scalar }
		return .Unsupported
	case 2:
		d0, d1 := shape[0], shape[1]
		if d0 == m && d1 == n { return .Full }
		if d0 == m && d1 == 1 { return .Row }
		if d0 == 1 && d1 == n { return .Col }
		if d0 == 1 && d1 == 1 { return .Scalar }
		return .Unsupported
	}
	return .Unsupported
}

// True if `param_id` is consumed by any node other than MatMul — MatMul
// indexes its own operands directly (row*K+k / k*N+col) and must not be
// reclassified against the kernel's [M,N] output shape.
gpu_param_used_outside_matmul :: proc(graph: ^Compute_Graph, param_id: GPU_Node_ID) -> bool {
	for node in graph.nodes {
		if node.kind == .MatMul { continue }
		for inp in node.inputs {
			if inp == param_id { return true }
		}
	}
	return false
}

// Validate that a matmul-mode (2D-dispatch) kernel can be correctly emitted
// under the current single row/col indexing scheme. Prints a diagnostic and
// returns false when it cannot — callers must not emit in that case.
gpu_validate_2d_kernel :: proc(graph: ^Compute_Graph, backend_name: string) -> bool {
	m, n, have_ref := gpu_kernel_ref_shape(graph)

	matmul_count := 0
	ref_k, ref_n2 := -1, -1
	ref_m2 := -1

	for &node in graph.nodes {
		#partial switch node.kind {
		case .Sum, .Mean, .Max, .Min, .Softmax, .CrossEntropy,
		     .Conv2d, .MaxPool2d, .AvgPool2d:
			fmt.eprintfln(
				"mimir compile-gpu: %s: kernel '%s' mixes matmul (2D row/col dispatch) with '%s' (linear thread-group reduction) in one unfused kernel — unsupported dispatch-mode combination; use --fuse to split into separate kernels",
				backend_name, graph.func_name, op_kind_string(node.kind))
			return false

		case .Transpose:
			a := get_node(graph, node.inputs[0])
			if a != nil && a.kind == .Param && len(a.name) > 0 {
				fmt.eprintfln(
					"mimir compile-gpu: %s: kernel '%s' mixes matmul (2D row/col dispatch) with a shared-memory Transpose tile (linear thread indexing) in one unfused kernel — unsupported dispatch-mode combination; use --fuse to split into separate kernels",
					backend_name, graph.func_name)
				return false
			}

		case .MatMul:
			if node.output_shape != nil && len(node.output_shape) == 2 {
				k := -1
				if len(node.inputs) >= 1 {
					a := get_node(graph, node.inputs[0])
					if a != nil && a.output_shape != nil && len(a.output_shape) >= 1 {
						k = a.output_shape[len(a.output_shape)-1]
					}
				}
				mm, nn := node.output_shape[0], node.output_shape[1]
				if matmul_count == 0 {
					ref_m2, ref_k, ref_n2 = mm, k, nn
				} else if mm != ref_m2 || k != ref_k || nn != ref_n2 {
					fmt.eprintfln(
						"mimir compile-gpu: %s: kernel '%s' chains multiple matmuls with different shapes ([%d,%d]x[%d,%d] vs [%d,%d]x[%d,%d]) in one unfused kernel — a single `dims` (M,K,N) uniform cannot represent both; use --fuse to split into separate kernels",
						backend_name, graph.func_name, ref_m2, ref_k, ref_k, ref_n2, mm, k, k, nn)
					return false
				}
				matmul_count += 1
			}

		case .Param:
			if !have_ref { continue }
			if !gpu_param_used_outside_matmul(graph, node.id) { continue }
			if gpu_param_bcast_mode(node.output_shape, m, n) == .Unsupported {
				fmt.eprintfln(
					"mimir compile-gpu: %s: kernel '%s' param '%s' has shape %v which cannot be statically broadcast against 2D kernel shape [%d, %d] (unsupported broadcast pattern)",
					backend_name, graph.func_name, node.name, node.output_shape, m, n)
				return false
			}
		}
	}
	return true
}

// Top-level emit dispatcher.
emit_kernel :: proc(
	graph: ^Compute_Graph,
	type_ctx: ^GPU_Type_Context,
	backend: Emit_Backend,
	allocator: mem.Allocator,
) -> (data: []u8, is_binary: bool, ok: bool) {
	bindings := assign_bindings(graph, allocator)

	switch backend {
	case .WGSL:
		s, wok := emit_wgsl(graph, type_ctx, &bindings, allocator)
		if !wok { return nil, false, false }
		return transmute([]u8)s, false, true
	case .MSL:
		s, mok := emit_msl(graph, type_ctx, &bindings, allocator)
		if !mok { return nil, false, false }
		return transmute([]u8)s, false, true
	case .SPIRV:
		d, sok := emit_spirv(graph, type_ctx, &bindings, allocator)
		if !sok { return nil, true, false }
		return d, true, true
	case .PTX:
		s, pok := emit_ptx(graph, type_ctx, &bindings, allocator)
		if !pok { return nil, false, false }
		return transmute([]u8)s, false, true
	}
	return nil, false, false
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
