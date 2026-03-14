package checker

import "core:fmt"
import "core:mem"

import parser "mimir:parser"
import binder "mimir:binder"
import flow   "mimir:flow"
import core   "mimir:core"

// ==================== Shape Semantics ====================
//
// Shape-aware type checking for mimir.array operations.
// Runs after forward inference — uses resolved Tensor_Types to
// validate matmul dimensions, reshape element conservation,
// and numpy-compatible broadcasting.

Shape_Semantic :: enum u8 {
	None,
	Creation,         // zeros, ones, array — first arg is shape
	Matmul,           // matmul — validate inner dims
	Reshape,          // reshape — validate element count
	Transpose,        // transpose — reverse dims
	Reduction,        // sum, mean — reduce to scalar
	Arange,           // arange — compute length from start/stop/step
}

// Tag each mimir.array export with its shape semantic
Shape_Registry :: struct {
	semantics: map[binder.Symbol_ID]Shape_Semantic,
}

init_shape_registry :: proc(allocator: mem.Allocator) -> Shape_Registry {
	return Shape_Registry{
		semantics = make(map[binder.Symbol_ID]Shape_Semantic, 16, allocator),
	}
}

// ==================== Shape Validation Rules ====================

// Validate matmul dimensions: a @ b requires a[-1] == b[-2] (or b[0] for 1D)
// Returns result shape and ok flag
validate_matmul :: proc(
	a_shape, b_shape: []int,
	allocator: mem.Allocator,
) -> (result: []int, ok: bool, err_msg: string) {
	a_ndim := len(a_shape)
	b_ndim := len(b_shape)

	if a_ndim == 0 || b_ndim == 0 {
		return {}, false, "matmul: scalar operands not supported"
	}

	// 1D @ 1D → dot product (scalar)
	if a_ndim == 1 && b_ndim == 1 {
		if a_shape[0] != -1 && b_shape[0] != -1 && a_shape[0] != b_shape[0] {
			return {}, false, fmt.aprintf(
				"matmul: dimension mismatch (%d,) @ (%d,), lengths %d ≠ %d",
				a_shape[0], b_shape[0], a_shape[0], b_shape[0],
				allocator = allocator)
		}
		return {}, true, "" // scalar result (0-dim)
	}

	// 1D @ 2D → vector-matrix: (K,) @ (K, N) → (N,)
	if a_ndim == 1 && b_ndim == 2 {
		if a_shape[0] != -1 && b_shape[0] != -1 && a_shape[0] != b_shape[0] {
			return {}, false, fmt.aprintf(
				"matmul: inner dimensions %d ≠ %d",
				a_shape[0], b_shape[0],
				allocator = allocator)
		}
		r := make([]int, 1, allocator)
		r[0] = b_shape[1]
		return r, true, ""
	}

	// 2D @ 1D → matrix-vector: (M, K) @ (K,) → (M,)
	if a_ndim == 2 && b_ndim == 1 {
		if a_shape[1] != -1 && b_shape[0] != -1 && a_shape[1] != b_shape[0] {
			return {}, false, fmt.aprintf(
				"matmul: inner dimensions %d ≠ %d",
				a_shape[1], b_shape[0],
				allocator = allocator)
		}
		r := make([]int, 1, allocator)
		r[0] = a_shape[0]
		return r, true, ""
	}

	// 2D @ 2D → matrix multiply: (M, K) @ (K, N) → (M, N)
	if a_ndim >= 2 && b_ndim >= 2 {
		a_inner := a_shape[a_ndim - 1]
		b_inner := b_shape[b_ndim - 2]
		if a_inner != -1 && b_inner != -1 && a_inner != b_inner {
			return {}, false, fmt.aprintf(
				"matmul: inner dimensions %d ≠ %d",
				a_inner, b_inner,
				allocator = allocator)
		}
		r := make([]int, 2, allocator)
		r[0] = a_shape[a_ndim - 2]
		r[1] = b_shape[b_ndim - 1]
		return r, true, ""
	}

	return {}, true, "" // Unhandled ndim combo — pass
}

// Validate reshape: product of old shape must equal product of new shape
validate_reshape :: proc(
	old_shape, new_shape: []int,
	allocator: mem.Allocator,
) -> (ok: bool, err_msg: string) {
	old_total := shape_product(old_shape)
	new_total := shape_product(new_shape)

	// If either has symbolic dims, can't validate
	if old_total < 0 || new_total < 0 {
		return true, ""
	}

	// -1 in new_shape means "infer this dimension"
	has_infer := false
	for d in new_shape {
		if d == -1 {
			if has_infer {
				return false, "reshape: only one dimension can be -1"
			}
			has_infer = true
		}
	}

	if has_infer {
		// Compute the inferred dimension
		known_product := 1
		for d in new_shape {
			if d != -1 { known_product *= d }
		}
		if known_product == 0 {
			return false, "reshape: cannot have zero-sized dimension with -1"
		}
		if old_total % known_product != 0 {
			return false, fmt.aprintf(
				"reshape: total elements %d not divisible by known dimensions product %d",
				old_total, known_product,
				allocator = allocator)
		}
		return true, ""
	}

	if old_total != new_total {
		return false, fmt.aprintf(
			"reshape: total elements mismatch (%d ≠ %d)",
			old_total, new_total,
			allocator = allocator)
	}

	return true, ""
}

// Compute broadcast result shape (numpy rules)
broadcast_shapes :: proc(
	a_shape, b_shape: []int,
	allocator: mem.Allocator,
) -> (result: []int, ok: bool, err_msg: string) {
	a_ndim := len(a_shape)
	b_ndim := len(b_shape)
	max_ndim := a_ndim if a_ndim > b_ndim else b_ndim

	r := make([]int, max_ndim, allocator)

	for i := 0; i < max_ndim; i += 1 {
		// Index from the right
		a_idx := a_ndim - 1 - i
		b_idx := b_ndim - 1 - i

		a_dim := a_shape[a_idx] if a_idx >= 0 else 1
		b_dim := b_shape[b_idx] if b_idx >= 0 else 1

		if a_dim == -1 || b_dim == -1 {
			// Symbolic — result is symbolic
			r[max_ndim - 1 - i] = -1
		} else if a_dim == b_dim {
			r[max_ndim - 1 - i] = a_dim
		} else if a_dim == 1 {
			r[max_ndim - 1 - i] = b_dim
		} else if b_dim == 1 {
			r[max_ndim - 1 - i] = a_dim
		} else {
			return {}, false, fmt.aprintf(
				"cannot broadcast shapes %s and %s: dimension %d ≠ %d",
				shape_to_string(a_shape, allocator),
				shape_to_string(b_shape, allocator),
				a_dim, b_dim,
				allocator = allocator)
		}
	}

	return r, true, ""
}

// ==================== Shape Extraction ====================

// Extract shape from a call expression's first argument.
// Handles: tuple literals (3, 4), single int literals, const-propagated values
extract_shape_from_arg :: proc(
	arg: parser.Expr,
	const_map: ^flow.Const_Map,
	bind_result: ^binder.Bind_Result,
	allocator: mem.Allocator,
) -> []int {
	if arg == nil { return {} }

	// Case 1: Tuple literal — (3, 4) or (2, 3, 4)
	if tuple, ok := arg.(^parser.Tuple_Expr); ok {
		return extract_shape_from_tuple(tuple, const_map, bind_result, allocator)
	}

	// Case 2: Single int literal — zeros(5)
	if c, ok := arg.(^parser.Constant_Expr); ok {
		if v, is_int := c.value.(i64); is_int {
			r := make([]int, 1, allocator)
			r[0] = int(v)
			return r
		}
	}

	// Case 3: Name referring to const-propagated tuple
	if name, ok := arg.(^parser.Name_Expr); ok && const_map != nil {
		sym_id, ref_ok := binder.get_ref(bind_result, rawptr(name))
		if ref_ok {
			if cv, found := const_map[sym_id]; found {
				return const_value_to_shape(cv, allocator)
			}
		}
	}

	return {} // Unknown shape
}

extract_shape_from_tuple :: proc(
	tuple: ^parser.Tuple_Expr,
	const_map: ^flow.Const_Map,
	bind_result: ^binder.Bind_Result,
	allocator: mem.Allocator,
) -> []int {
	dims := make([]int, len(tuple.elts), allocator)
	for elt, i in tuple.elts {
		if c, ok := elt.(^parser.Constant_Expr); ok {
			if v, is_int := c.value.(i64); is_int {
				dims[i] = int(v)
				continue
			}
		}
		// Try const_map for Name_Expr
		if name, ok := elt.(^parser.Name_Expr); ok && const_map != nil {
			sym_id, ref_ok := binder.get_ref(bind_result, rawptr(name))
			if ref_ok {
				if cv, found := const_map[sym_id]; found {
					if ci, is_ci := cv.(flow.Const_Int); is_ci {
						dims[i] = int(ci.value)
						continue
					}
				}
			}
		}
		dims[i] = -1 // Unknown dimension
	}
	return dims
}

const_value_to_shape :: proc(cv: flow.Const_Value, allocator: mem.Allocator) -> []int {
	#partial switch v in cv {
	case flow.Const_Int:
		r := make([]int, 1, allocator)
		r[0] = int(v.value)
		return r
	case flow.Const_Tuple:
		r := make([]int, len(v.elements), allocator)
		for elt, i in v.elements {
			if ci, ok := elt.(flow.Const_Int); ok {
				r[i] = int(ci.value)
			} else {
				r[i] = -1
			}
		}
		return r
	}
	return {}
}

// Extract shape for arange: arange(stop) → (stop,), arange(start, stop) → (stop-start,)
extract_arange_shape :: proc(args: []parser.Expr, allocator: mem.Allocator) -> []int {
	// arange has 1-3 args: arange(stop), arange(start, stop), arange(start, stop, step)
	vals := make([]i64, len(args), allocator)
	all_const := true
	for arg, i in args {
		if c, ok := arg.(^parser.Constant_Expr); ok {
			if v, is_int := c.value.(i64); is_int {
				vals[i] = v
				continue
			}
		}
		all_const = false
		break
	}

	if !all_const { return {} }

	start, stop, step: i64
	switch len(args) {
	case 1:
		start = 0; stop = vals[0]; step = 1
	case 2:
		start = vals[0]; stop = vals[1]; step = 1
	case 3:
		start = vals[0]; stop = vals[1]; step = vals[2]
		if step == 0 { return {} }
	case:
		return {}
	}

	length: i64
	if step > 0 {
		length = (stop - start + step - 1) / step
	} else {
		// Negative step: count from start down to stop
		length = (start - stop - step - 1) / (-step)
	}
	if length < 0 { length = 0 }

	r := make([]int, 1, allocator)
	r[0] = int(length)
	return r
}

// ==================== Shape Analysis Pass ====================

// Run shape analysis on all scopes. Called after type checking.
analyze_shapes :: proc(
	flow_result: ^flow.Flow_Result,
	result: ^Check_Result,
	bind_result: ^binder.Bind_Result,
	shape_reg: ^Shape_Registry,
	file_path: string,
	allocator: mem.Allocator,
) {
	reg := &result.registry

	// Walk all expressions looking for tensor operations
	for &cfg in flow_result.cfgs {
		const_map: ^flow.Const_Map = nil
		if cm, ok := &flow_result.const_maps[cfg.scope_id]; ok {
			const_map = cm
		}

		for &block in cfg.blocks {
			if !block.is_reachable { continue }
			for stmt in block.stmts {
				check_shape_stmt(stmt, result, bind_result, reg, shape_reg, const_map, file_path, allocator)
			}
		}
	}
}

check_shape_stmt :: proc(
	stmt: parser.Stmt,
	result: ^Check_Result,
	bind_result: ^binder.Bind_Result,
	reg: ^Type_Registry,
	shape_reg: ^Shape_Registry,
	const_map: ^flow.Const_Map,
	file_path: string,
	allocator: mem.Allocator,
) {
	// Look for assignment statements with call RHS
	#partial switch s in stmt {
	case ^parser.Assign:
		if s.value != nil {
			check_shape_expr(s.value, result, bind_result, reg, shape_reg, const_map, file_path, allocator)
		}
	case ^parser.Ann_Assign:
		if s.value != nil {
			check_shape_expr(s.value, result, bind_result, reg, shape_reg, const_map, file_path, allocator)
		}
	case ^parser.Expr_Stmt:
		if s.value != nil {
			check_shape_expr(s.value, result, bind_result, reg, shape_reg, const_map, file_path, allocator)
		}
	case ^parser.Return_Stmt:
		if s.value != nil {
			check_shape_expr(s.value, result, bind_result, reg, shape_reg, const_map, file_path, allocator)
		}
	}
}

check_shape_expr :: proc(
	expr: parser.Expr,
	result: ^Check_Result,
	bind_result: ^binder.Bind_Result,
	reg: ^Type_Registry,
	shape_reg: ^Shape_Registry,
	const_map: ^flow.Const_Map,
	file_path: string,
	allocator: mem.Allocator,
) {
	if expr == nil { return }

	#partial switch e in expr {
	case ^parser.Call_Expr:
		// Check if this is a mimir.array function call with shape semantics
		check_shape_call(e, result, bind_result, reg, shape_reg, const_map, file_path, allocator)

	case ^parser.Bin_Op_Expr:
		// Check tensor binops (broadcasting, matmul)
		check_shape_binop(e, result, bind_result, reg, file_path, allocator)

		// Recurse into operands
		check_shape_expr(e.left, result, bind_result, reg, shape_reg, const_map, file_path, allocator)
		check_shape_expr(e.right, result, bind_result, reg, shape_reg, const_map, file_path, allocator)
	}
}

check_shape_call :: proc(
	e: ^parser.Call_Expr,
	result: ^Check_Result,
	bind_result: ^binder.Bind_Result,
	reg: ^Type_Registry,
	shape_reg: ^Shape_Registry,
	const_map: ^flow.Const_Map,
	file_path: string,
	allocator: mem.Allocator,
) {
	// Resolve function symbol
	func_sym: binder.Symbol_ID
	if name, ok := e.func.(^parser.Name_Expr); ok {
		sym_id, ref_ok := binder.get_ref(bind_result, rawptr(name))
		if !ref_ok { return }
		func_sym = sym_id
	} else {
		return
	}

	semantic, has := shape_reg.semantics[func_sym]
	if !has { return }

	switch semantic {
	case .Matmul:
		check_matmul_call(e, result, reg, file_path, allocator)
	case .Reshape:
		check_reshape_call(e, result, bind_result, reg, const_map, file_path, allocator)
	case .None, .Creation, .Transpose, .Reduction, .Arange:
		// No validation needed for these at call site
	}
}

check_matmul_call :: proc(
	e: ^parser.Call_Expr,
	result: ^Check_Result,
	reg: ^Type_Registry,
	file_path: string,
	allocator: mem.Allocator,
) {
	if len(e.args) < 2 { return }

	a_type := shape_get_expr_type(result, e.args[0])
	b_type := shape_get_expr_type(result, e.args[1])

	a_tensor := get_tensor_info(reg, a_type)
	b_tensor := get_tensor_info(reg, b_type)

	if a_tensor == nil || b_tensor == nil { return }
	if a_tensor.ndim == 0 || b_tensor.ndim == 0 { return } // Shape-erased

	_, ok, err_msg := validate_matmul(a_tensor.shape, b_tensor.shape, allocator)
	if !ok {
		append(&result.diagnostics, core.Diagnostic{
			severity = .Error,
			location = core.Location{
				file   = file_path,
				line   = int(e.loc.line),
				column = int(e.loc.col),
			},
			code = "SHAPE001",
			what = "Matmul dimension mismatch",
			why  = err_msg,
			fix  = "Ensure inner dimensions match or transpose one operand",
		})
	}
}

check_reshape_call :: proc(
	e: ^parser.Call_Expr,
	result: ^Check_Result,
	bind_result: ^binder.Bind_Result,
	reg: ^Type_Registry,
	const_map: ^flow.Const_Map,
	file_path: string,
	allocator: mem.Allocator,
) {
	if len(e.args) < 2 { return }

	a_type := shape_get_expr_type(result, e.args[0])
	a_tensor := get_tensor_info(reg, a_type)
	if a_tensor == nil || a_tensor.ndim == 0 { return } // Shape-erased

	// Extract new shape from second argument
	new_shape := extract_shape_from_arg(e.args[1], const_map, bind_result, allocator)
	if len(new_shape) == 0 { return } // Can't determine new shape

	ok, err_msg := validate_reshape(a_tensor.shape, new_shape, allocator)
	if !ok {
		append(&result.diagnostics, core.Diagnostic{
			severity = .Error,
			location = core.Location{
				file   = file_path,
				line   = int(e.loc.line),
				column = int(e.loc.col),
			},
			code = "SHAPE002",
			what = "Reshape element count mismatch",
			why  = err_msg,
			fix  = "Ensure total number of elements matches",
		})
	}
}

check_shape_binop :: proc(
	e: ^parser.Bin_Op_Expr,
	result: ^Check_Result,
	bind_result: ^binder.Bind_Result,
	reg: ^Type_Registry,
	file_path: string,
	allocator: mem.Allocator,
) {
	left_type := shape_get_expr_type(result, e.left)
	right_type := shape_get_expr_type(result, e.right)

	left_tensor := get_tensor_info(reg, left_type)
	right_tensor := get_tensor_info(reg, right_type)

	// Only check when both operands are shaped tensors
	if left_tensor == nil || right_tensor == nil { return }
	if left_tensor.ndim == 0 || right_tensor.ndim == 0 { return }

	#partial switch e.op {
	case .Mat_Mult:
		// a @ b — same as matmul
		_, ok, err_msg := validate_matmul(left_tensor.shape, right_tensor.shape, allocator)
		if !ok {
			append(&result.diagnostics, core.Diagnostic{
				severity = .Error,
				location = core.Location{
					file   = file_path,
					line   = int(e.loc.line),
					column = int(e.loc.col),
				},
				code = "SHAPE001",
				what = "Matmul dimension mismatch",
				why  = err_msg,
				fix  = "Ensure inner dimensions match or transpose one operand",
			})
		}

	case .Add, .Sub, .Mult, .Div, .Pow, .Mod, .Floor_Div:
		// Elementwise ops require broadcasting compatibility
		_, ok, err_msg := broadcast_shapes(left_tensor.shape, right_tensor.shape, allocator)
		if !ok {
			append(&result.diagnostics, core.Diagnostic{
				severity = .Error,
				location = core.Location{
					file   = file_path,
					line   = int(e.loc.line),
					column = int(e.loc.col),
				},
				code = "SHAPE003",
				what = "Incompatible broadcast shapes",
				why  = err_msg,
				fix  = "Reshape one operand to make shapes broadcast-compatible",
			})
		}

	case: // Other ops — no shape validation
	}
}

// ==================== Helpers ====================

shape_get_expr_type :: proc(result: ^Check_Result, expr: parser.Expr) -> Type_ID {
	ptr := rawptr_from_expr(expr)
	if ptr == nil { return TYPE_UNKNOWN }
	if t, ok := result.expr_types[ptr]; ok {
		return t
	}
	return TYPE_UNKNOWN
}

// Extract Tensor_Type info from a Type_ID, returns nil if not a tensor
get_tensor_info :: proc(reg: ^Type_Registry, type_id: Type_ID) -> ^Tensor_Type {
	if type_id == TYPE_UNKNOWN || type_id == TYPE_ANY { return nil }
	t := get_type(reg, type_id)
	#partial switch &info in t.info {
	case Tensor_Type:
		return &info
	}
	return nil
}

shape_product :: proc(shape: []int) -> int {
	if len(shape) == 0 { return 0 }
	product := 1
	for d in shape {
		if d < 0 { return -1 } // Symbolic
		product *= d
	}
	return product
}

shape_to_string :: proc(shape: []int, allocator: mem.Allocator) -> string {
	buf := make([dynamic]u8, 0, 32, allocator)
	append(&buf, '(')
	for d, i in shape {
		if i > 0 {
			append(&buf, ',')
			append(&buf, ' ')
		}
		if d == -1 {
			append(&buf, '?')
		} else {
			ds := fmt.tprintf("%d", d)
			for c in ds { append(&buf, u8(c)) }
		}
	}
	if len(shape) == 1 {
		append(&buf, ',')
	}
	append(&buf, ')')
	return string(buf[:])
}

