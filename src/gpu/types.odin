package gpu

import "core:mem"

import checker "mimir:checker"
import parser "mimir:parser"

// GPU numeric precision types — only valid inside @gpu functions.
// These map to hardware-supported precisions, NOT Python's float (float64).

GPU_Type_Context :: struct {
	reg:         ^checker.Type_Registry,
	allocator:   mem.Allocator,
	// Registered precision type IDs
	float32_id:  checker.Type_ID,
	float16_id:  checker.Type_ID,
	bfloat16_id: checker.Type_ID,
	int32_id:    checker.Type_ID,
	int64_id:    checker.Type_ID,
	// Map of gpu type name → type ID for annotation resolution
	gpu_names:   map[string]checker.Type_ID,
}

init_gpu_types :: proc(reg: ^checker.Type_Registry, allocator: mem.Allocator) -> GPU_Type_Context {
	ctx: GPU_Type_Context
	ctx.reg = reg
	ctx.allocator = allocator

	// Register GPU precision types as named types
	ctx.float32_id  = checker.register_type(reg, checker.Primitive_Type{.Float})
	ctx.float16_id  = checker.register_type(reg, checker.Primitive_Type{.Float})
	ctx.bfloat16_id = checker.register_type(reg, checker.Primitive_Type{.Float})
	ctx.int32_id    = checker.register_type(reg, checker.Primitive_Type{.Int})
	ctx.int64_id    = checker.register_type(reg, checker.Primitive_Type{.Int})

	ctx.gpu_names = make(map[string]checker.Type_ID, 8, allocator)
	ctx.gpu_names["float32"]  = ctx.float32_id
	ctx.gpu_names["float16"]  = ctx.float16_id
	ctx.gpu_names["bfloat16"] = ctx.bfloat16_id
	ctx.gpu_names["int32"]    = ctx.int32_id
	ctx.gpu_names["int64"]    = ctx.int64_id

	return ctx
}

// Check if a type ID is a GPU-compatible numeric type.
is_gpu_numeric :: proc(type_id: checker.Type_ID, ctx: ^GPU_Type_Context) -> bool {
	if type_id == ctx.float32_id  { return true }
	if type_id == ctx.float16_id  { return true }
	if type_id == ctx.bfloat16_id { return true }
	if type_id == ctx.int32_id    { return true }
	if type_id == ctx.int64_id    { return true }
	// Also accept standard numeric types
	if type_id == checker.TYPE_INT   { return true }
	if type_id == checker.TYPE_FLOAT { return true }
	if type_id == checker.TYPE_BOOL  { return true }
	return false
}

// Resolve a GPU type annotation like `Tensor[float32, 32, 3]`.
// Returns INVALID_TYPE if annotation is not a GPU type.
resolve_gpu_annotation :: proc(expr: parser.Expr, ctx: ^GPU_Type_Context) -> checker.Type_ID {
	// Case 1: bare name like `float32`
	#partial switch e in expr {
	case ^parser.Name_Expr:
		if tid, ok := ctx.gpu_names[e.id]; ok {
			return tid
		}
		return checker.INVALID_TYPE

	// Case 2: Tensor[dtype, dim1, dim2, ...]
	case ^parser.Subscript_Expr:
		// Check value is "Tensor"
		#partial switch v in e.value {
		case ^parser.Name_Expr:
			if v.id != "Tensor" { return checker.INVALID_TYPE }
		case:
			return checker.INVALID_TYPE
		}

		// Parse subscript args
		#partial switch s in e.slice {
		case ^parser.Tuple_Expr:
			if len(s.elts) < 1 { return checker.INVALID_TYPE }
			// First element: dtype
			dtype_id := resolve_gpu_dtype(s.elts[0], ctx)
			if dtype_id == checker.INVALID_TYPE { return checker.INVALID_TYPE }
			// Remaining elements: shape dimensions
			shape := make([dynamic]int, 0, len(s.elts) - 1, ctx.allocator)
			for i := 1; i < len(s.elts); i += 1 {
				dim := extract_int_constant(s.elts[i])
				append(&shape, dim)
			}
			return checker.make_tensor_type(ctx.reg, dtype_id, shape[:])

		case ^parser.Name_Expr:
			// Tensor[float32] — shape-erased
			dtype_id := resolve_gpu_dtype(expr_from_name(s), ctx)
			if dtype_id == checker.INVALID_TYPE { return checker.INVALID_TYPE }
			return checker.make_tensor_type(ctx.reg, dtype_id, nil)

		case:
			return checker.INVALID_TYPE
		}
	}
	return checker.INVALID_TYPE
}

// Resolve a dtype expression (Name_Expr) to a GPU type ID.
resolve_gpu_dtype :: proc(expr: parser.Expr, ctx: ^GPU_Type_Context) -> checker.Type_ID {
	#partial switch e in expr {
	case ^parser.Name_Expr:
		if tid, ok := ctx.gpu_names[e.id]; ok {
			return tid
		}
	}
	return checker.INVALID_TYPE
}

// Helper: extract integer constant or symbolic dimension from an expression.
// Returns positive int for concrete dims, <= SYMBOLIC_DIM_BASE for symbolic dims, -1 for unknown.
extract_int_constant :: proc(expr: parser.Expr) -> int {
	#partial switch e in expr {
	case ^parser.Constant_Expr:
		#partial switch v in e.value {
		case i64:
			return int(v)
		}
	case ^parser.Unary_Op_Expr:
		if e.op == .USub {
			inner := extract_int_constant(e.operand)
			return -inner
		}
	case ^parser.Name_Expr:
		// Symbolic dimension variable: single uppercase letter → deterministic ID
		// N → -2, M → -3, K → -4, B → -5, C → -6, etc.
		if len(e.id) == 1 {
			ch := e.id[0]
			if ch >= 'A' && ch <= 'Z' {
				return checker.SYMBOLIC_DIM_BASE - int(ch - 'A')
			}
		}
		// Multi-char symbolic dim names: hash to a negative ID
		if len(e.id) > 0 && e.id[0] >= 'A' && e.id[0] <= 'Z' {
			h := 0
			for c in e.id { h = h * 31 + int(c) }
			return checker.SYMBOLIC_DIM_BASE - (h % 1000) - 26
		}
	}
	return -1 // unknown
}

// Helper to treat a ^Name_Expr as Expr for dtype resolution.
expr_from_name :: proc(n: ^parser.Name_Expr) -> parser.Expr {
	return parser.Expr(n)
}

// Product of all dimensions. Returns -1 if any dim is symbolic or shape is nil.
shape_product :: proc(shape: []int) -> int {
	if shape == nil { return -1 }
	prod := 1
	for d in shape {
		if d < 0 { return -1 }
		prod *= d
	}
	return prod
}

// Numpy-style broadcasting: right-align shapes, take max dim where compatible.
broadcast_result_shape :: proc(a, b: []int, allocator: mem.Allocator) -> ([]int, bool) {
	if a == nil || b == nil { return nil, false }
	max_rank := max(len(a), len(b))
	result := make([]int, max_rank, allocator)
	for i := 0; i < max_rank; i += 1 {
		ai := a[len(a) - 1 - i] if i < len(a) else 1
		bi := b[len(b) - 1 - i] if i < len(b) else 1
		if ai == bi {
			result[max_rank - 1 - i] = ai
		} else if ai == -1 || bi == -1 {
			result[max_rank - 1 - i] = -1  // propagate symbolic
		} else if ai == 1 {
			result[max_rank - 1 - i] = bi
		} else if bi == 1 {
			result[max_rank - 1 - i] = ai
		} else {
			return nil, false // incompatible
		}
	}
	return result, true
}

// Resolve -1 wildcard in target shape. product(from) == product(to).
reshape_infer :: proc(from_shape, to_shape: []int, allocator: mem.Allocator) -> ([]int, bool) {
	if from_shape == nil || to_shape == nil { return nil, false }
	from_prod := shape_product(from_shape)
	if from_prod <= 0 { return to_shape, true } // symbolic — can't infer

	neg_idx := -1
	known_prod := 1
	for d, i in to_shape {
		if d == -1 {
			if neg_idx >= 0 { return nil, false } // multiple -1s
			neg_idx = i
		} else if d <= 0 {
			return nil, false // invalid dim
		} else {
			known_prod *= d
		}
	}

	if neg_idx < 0 {
		// No wildcard — just check products match
		if known_prod != from_prod { return nil, false }
		return to_shape, true
	}

	// Infer the -1 dim
	if from_prod % known_prod != 0 { return nil, false }
	result := make([]int, len(to_shape), allocator)
	copy(result, to_shape)
	result[neg_idx] = from_prod / known_prod
	return result, true
}

// Map a type to byte width: float32→4, float16→2, bfloat16→2, int32→4, int64→8.
element_byte_size :: proc(type_id: checker.Type_ID, ctx: ^GPU_Type_Context) -> int {
	if type_id == ctx.float16_id || type_id == ctx.bfloat16_id { return 2 }
	if type_id == ctx.float32_id { return 4 }
	if type_id == ctx.int32_id { return 4 }
	if type_id == ctx.int64_id { return 8 }
	if type_id == checker.TYPE_FLOAT { return 4 }
	if type_id == checker.TYPE_INT { return 4 }
	if type_id == checker.TYPE_BOOL { return 1 }
	// Resolve tensor element type
	t := checker.get_type(ctx.reg, type_id)
	#partial switch info in t.info {
	case checker.Tensor_Type:
		return element_byte_size(info.element_type, ctx)
	}
	return 4 // default float32
}

// Total byte size for a shaped buffer.
shape_byte_size :: proc(shape: []int, element_bytes: int) -> int {
	prod := shape_product(shape)
	if prod < 0 { return -1 }
	return prod * element_bytes
}

// Check if two shapes are compatible for elementwise operations.
shape_compatible :: proc(a: []int, b: []int) -> bool {
	if len(a) != len(b) { return false }
	for i := 0; i < len(a); i += 1 {
		if a[i] == -1 || b[i] == -1 { continue }
		if a[i] != b[i] { return false }
	}
	return true
}

// Compute matmul result shape: [M, K] @ [K, N] → [M, N].
// Returns (result_shape, ok).
matmul_result_shape :: proc(a: []int, b: []int, allocator: mem.Allocator) -> ([]int, bool) {
	if len(a) < 2 || len(b) < 2 { return nil, false }
	k_a := a[len(a) - 1]
	k_b := b[len(b) - 2]
	// K dimensions must match (or be symbolic)
	if k_a != -1 && k_b != -1 && k_a != k_b { return nil, false }
	result := make([]int, 2, allocator)
	result[0] = a[len(a) - 2] // M
	result[1] = b[len(b) - 1] // N
	return result, true
}
