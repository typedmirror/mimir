package checker

import "core:mem"
import "core:strings"

import parser "mimir:parser"
import binder "mimir:binder"
import flow   "mimir:flow"
import core   "mimir:core"

// ==================== Expression Type Inference ====================

Match_Case_Env :: struct {
	bindings: map[binder.Symbol_ID]Type_ID,
}

Infer_Context :: struct {
	env:            ^Type_Env,
	reg:            ^Type_Registry,
	bind_result:    ^binder.Bind_Result,
	builtins:       ^Builtin_Names,
	expr_types:     ^map[rawptr]Type_ID,
	diagnostics:    ^[dynamic]core.Diagnostic,
	file_path:      string,
	declared_types: ^map[binder.Symbol_ID]Type_ID,
	current_class:  Type_ID,
	scope_id:       binder.Scope_ID,
	global_types:   ^map[binder.Symbol_ID]Type_ID, // Module-level symbol types (LEGB "G" fallback)
	shape_reg:      ^Shape_Registry,               // Shape semantics for mimir.array functions
	const_map:      ^flow.Const_Map,               // Constant propagation results for shape extraction
	cfg:              ^flow.CFG,                           // CFG for match case block mapping
	current_block:    flow.Block_ID,                     // Current block being processed
	match_case_envs:  ^map[flow.Block_ID]Match_Case_Env, // Pattern bindings per case block
	groupby_sources:  ^map[binder.Symbol_ID]GroupBy_Info, // symbol → groupby source info for column tracking
	closed_vars:      ^map[binder.Symbol_ID]parser.Src_Loc, // §4.2: variables closed after with-block exit
	final_vars:       ^map[binder.Symbol_ID]bool,              // Final[T]: variables that cannot be reassigned
	resolved_types:   ^map[binder.Symbol_ID]Type_ID,           // Constraint-resolved types for unknown symbols (re-inference pass)
	generator_send_types: ^map[binder.Scope_ID]Type_ID,      // Generator[Y,S,R] → S per scope
	type_ignore_lines: ^map[i32]bool,                         // Lines with # type: ignore comments
}

infer_expr :: proc(expr: parser.Expr, ctx: ^Infer_Context, expected: Type_ID = TYPE_UNKNOWN) -> Type_ID {
	if expr == nil { return TYPE_UNKNOWN }

	result := infer_expr_inner(expr, ctx, expected)

	// Record in expr_types map
	ctx.expr_types[expr_to_rawptr(expr)] = result

	return result
}

infer_expr_inner :: proc(expr: parser.Expr, ctx: ^Infer_Context, expected: Type_ID) -> Type_ID {
	switch e in expr {
	case ^parser.Constant_Expr:
		return infer_constant(e, ctx.reg, expected)

	case ^parser.Name_Expr:
		return infer_name(e, ctx)

	case ^parser.Bin_Op_Expr:
		left := infer_expr(e.left, ctx)
		right := infer_expr(e.right, ctx)
		result := infer_binop(e.op, left, right, ctx.reg)
		if result == TYPE_UNKNOWN && left != TYPE_UNKNOWN && right != TYPE_UNKNOWN &&
		   !_is_any_type(left, ctx.reg) && !_is_any_type(right, ctx.reg) &&
		   !_union_has_unknown(left, ctx.reg) && !_union_has_unknown(right, ctx.reg) {
			emit_diagnostic(ctx, e.loc, "T005", .Error,
				"Unsupported operand types",
				fmt_binop_error(e.op, left, right, ctx.reg),
				"Check operand types or add explicit conversion")
		}
		// Refine tensor binop shapes (infer_binop returns shape-erased)
		if result != TYPE_UNKNOWN {
			lt := get_tensor_info(ctx.reg, left)
			rt := get_tensor_info(ctx.reg, right)
			if lt != nil && rt != nil && lt.ndim > 0 && rt.ndim > 0 {
				if e.op == .Mat_Mult {
					r_shape, ok, _ := validate_matmul(lt.shape, rt.shape, ctx.reg.allocator)
					if ok {
						result = make_tensor_type(ctx.reg, lt.element_type, r_shape)
					}
				} else {
					r_shape, ok, _ := broadcast_shapes(lt.shape, rt.shape, ctx.reg.allocator)
					if ok {
						result = make_tensor_type(ctx.reg, lt.element_type, r_shape)
					}
				}
			}
		}
		return result

	case ^parser.Unary_Op_Expr:
		operand := infer_expr(e.operand, ctx)
		result := infer_unaryop(e.op, operand, ctx.reg)
		if result == TYPE_UNKNOWN && operand != TYPE_UNKNOWN && operand != TYPE_ANY &&
		   !_is_any_type(operand, ctx.reg) && !_union_has_unknown(operand, ctx.reg) {
			emit_diagnostic(ctx, e.loc, "T005", .Error,
				"Unsupported operand type",
				fmt.aprintf("Cannot apply unary '%s' to '%s'",
					e.op == .USub ? "-" : e.op == .UAdd ? "+" : e.op == .Invert ? "~" : "not",
					type_to_string(ctx.reg, operand),
					allocator = ctx.reg.allocator),
				"Check operand type or add explicit conversion")
		}
		return result

	case ^parser.Compare_Expr:
		// Type-check all operands, result is always bool
		infer_expr(e.left, ctx)
		for comp in e.comparators {
			infer_expr(comp, ctx)
		}
		return TYPE_BOOL

	case ^parser.Bool_Op_Expr:
		// and/or: result is union of operand types
		types := make([dynamic]Type_ID, 0, len(e.values), ctx.reg.allocator)
		for v in e.values {
			append(&types, infer_expr(v, ctx, expected))
		}
		// For `or`: None from non-last operands can be removed.
		// `x or y` where x: T|None → if x is None (falsy), result is y, never None.
		if e.op == .Or && len(types) > 1 {
			filtered := make([dynamic]Type_ID, 0, len(types), ctx.reg.allocator)
			for t, i in types {
				if i < len(types) - 1 {
					// Non-last operand: strip None from union types
					tt := get_type(ctx.reg, t)
					if ut, is_union := tt.info.(Union_Type); is_union {
						non_none := make([dynamic]Type_ID, 0, len(ut.members), ctx.reg.allocator)
						for m in ut.members {
							if m != TYPE_NONE { append(&non_none, m) }
						}
						if len(non_none) > 0 && len(non_none) < len(ut.members) {
							if len(non_none) == 1 {
								append(&filtered, non_none[0])
							} else {
								append(&filtered, make_union_type(ctx.reg, non_none[:]))
							}
							continue
						}
					}
					if t != TYPE_NONE {
						append(&filtered, t)
					}
				} else {
					append(&filtered, t) // Last operand kept as-is
				}
			}
			if len(filtered) > 0 {
				return make_union_type(ctx.reg, filtered[:])
			}
		}
		return make_union_type(ctx.reg, types[:])

	case ^parser.Call_Expr:
		return infer_call(e, ctx, expected)

	case ^parser.Attribute_Expr:
		// SAF010: use-after-close check (§4.2 context manager typestate)
		if ctx.closed_vars != nil {
			if name, is_name := e.value.(^parser.Name_Expr); is_name {
				if sym_id := _match_lookup_sym(name.id, ctx); sym_id != 0 {
					if _, is_closed := ctx.closed_vars[sym_id]; is_closed {
						RESOURCE_METHODS :: [?]string{"read", "write", "readline", "readlines", "writelines", "seek", "tell", "flush", "fileno", "truncate", "send", "recv", "sendall"}
						for m in RESOURCE_METHODS {
							if e.attr == m {
								emit_diagnostic(ctx, e.loc, "SAF010", .Error,
									fmt.aprintf("use after close: '%s.%s()' called after 'with' block exited",
										name.id, e.attr, allocator = ctx.reg.allocator),
									"the resource was closed when the 'with' block ended — accessing it is an error",
									fmt.aprintf("move '%s.%s()' inside the 'with' block", name.id, e.attr, allocator = ctx.reg.allocator))
								break
							}
						}
					}
				}
			}
		}
		receiver := infer_expr(e.value, ctx)
		// Check for narrowed attribute type from guard (e.g., after `if obj.attr is not None:`)
		if name, is_name := e.value.(^parser.Name_Expr); is_name {
			sym_id, ref_ok := binder.get_ref(ctx.bind_result, rawptr(name))
			if ref_ok {
				key := attr_narrow_key(sym_id, e.attr)
				if narrowed, has := ctx.env.attr_types[key]; has {
					return narrowed
				}
			}
		}
		result := lookup_attribute(receiver, e.attr, ctx.reg)
		// T007: flag undefined attributes on user-defined types
		if result == TYPE_UNKNOWN && receiver != TYPE_UNKNOWN && receiver != TYPE_ANY {
			rt := get_type(ctx.reg, receiver)
			should_flag := false
			#partial switch ri in rt.info {
			case Instance_Type:
				// Only flag if class has known attrs AND attr is not in the map
				cls := get_type(ctx.reg, ri.class_type)
				if ci, ci_ok := cls.info.(Class_Type); ci_ok {
					if len(ci.attrs) > 0 {
						_, attr_exists := ci.attrs[e.attr]
						should_flag = !attr_exists
					}
					// Suppress T007 when class inherits from Any (all attrs valid)
					if should_flag {
						for base_id in ci.bases {
							if base_id == TYPE_ANY || _is_any_type(base_id, ctx.reg) {
								should_flag = false
								break
							}
						}
					}
				}
			case Class_Type:
				// Class object attribute resolution is incomplete (no classmethods, class vars).
				// Only flag on classes with enough attrs to be confident.
				should_flag = len(ri.attrs) > 1
			case Module_Type:
				should_flag = len(ri.exports) > 0
			case Protocol_Type:
				should_flag = len(ri.methods) > 0 || len(ri.attrs) > 0
			case TypedDict_Type:
				should_flag = len(ri.fields) > 0
			case DataFrame_Type, Series_Type, Tensor_Type:
				should_flag = true
			case Primitive_Type:
				// Only flag for str — we have comprehensive str method handlers.
				// Other primitives (bytes, int, float) have methods we don't fully model.
				if receiver == TYPE_STR { should_flag = true }
			}
			// Skip dunder attrs — implicit object methods not tracked yet
			// Skip private attrs (_prefix) — instance attrs from __init__ not tracked
			is_dunder := len(e.attr) > 4 && e.attr[:2] == "__" && e.attr[len(e.attr)-2:] == "__"
			is_private := len(e.attr) > 1 && e.attr[0] == '_' && !is_dunder
			// Skip self.attr in method bodies — attrs may be set dynamically in methods
			is_self_access := false
			if name, nok := e.value.(^parser.Name_Expr); nok {
				if name.id == "self" && ctx.current_class != INVALID_TYPE { is_self_access = true }
			}
			if should_flag && !is_dunder && !is_private && !is_self_access {
				emit_diagnostic(ctx, e.loc, "T007", .Error,
					"Undefined attribute",
					fmt.aprintf("Type '%s' has no attribute '%s'",
						type_to_string(ctx.reg, receiver),
						e.attr,
						allocator = ctx.reg.allocator),
					"Check the attribute name or class definition")
			}
		}
		return result

	case ^parser.Subscript_Expr:
		container := infer_expr(e.value, ctx)
		infer_expr(e.slice, ctx) // type-check the index
		// TypedDict key access validation
		ct := get_type(ctx.reg, container)
		#partial switch &td in ct.info {
		case TypedDict_Type:
			#partial switch key_expr in e.slice {
			case ^parser.Constant_Expr:
				if key_str, ok := key_expr.value.(string); ok {
					if field_type, found := td.fields[key_str]; found {
						return field_type
					}
					// "Did you mean?" suggestion via edit distance
					fix_msg := "Use a valid key"
					best_name := ""
					best_dist := 3
					for field_name in td.fields {
						d := _edit_distance(key_str, field_name)
						if d < best_dist {
							best_dist = d
							best_name = field_name
						}
					}
					if len(best_name) > 0 {
						fix_msg = fmt.aprintf("Did you mean '%s'?", best_name,
							allocator = ctx.reg.allocator)
					}
					td_display := td.name if len(td.name) > 0 else "inferred"
					emit_diagnostic(ctx, e.loc, "T001", .Error,
						"Invalid TypedDict key",
						fmt.aprintf("TypedDict '%s' has no key '%s'", td_display, key_str,
							allocator = ctx.reg.allocator),
						fix_msg)
					return TYPE_UNKNOWN
				}
			}
			return TYPE_UNKNOWN
		case DataFrame_Type:
			return resolve_dataframe_subscript(ctx, &td, e)
		case Series_Type:
			// Series indexing: s[0] → element, s[0:5] → same Series
			if _, is_slice := e.slice.(^parser.Slice_Expr); is_slice {
				return container
			}
			return td.element
		}
		// Slicing returns the same container type; indexing returns element type
		if _, is_slice := e.slice.(^parser.Slice_Expr); is_slice {
			return container
		}
		return get_subscript_type(container, ctx.reg)

	case ^parser.List_Expr:
		// Extract expected element type for contextual typing
		elem_expected := TYPE_UNKNOWN
		if expected != TYPE_UNKNOWN {
			exp_t := get_type(ctx.reg, expected)
			#partial switch exp_info in exp_t.info {
			case List_Type:
				elem_expected = exp_info.element
			}
		}
		if len(e.elts) == 0 {
			if elem_expected != TYPE_UNKNOWN {
				return make_list_type(ctx.reg, elem_expected)
			}
			return make_list_type(ctx.reg, TYPE_UNKNOWN)
		}
		elem_types := make([dynamic]Type_ID, 0, len(e.elts), ctx.reg.allocator)
		all_match := elem_expected != TYPE_UNKNOWN
		for elt in e.elts {
			et := infer_expr(elt, ctx, elem_expected)
			append(&elem_types, et)
			if all_match && !is_assignable(ctx.reg, et, elem_expected) {
				all_match = false
			}
		}
		if all_match {
			return make_list_type(ctx.reg, elem_expected)
		}
		elem := unify_types(elem_types[:], ctx.reg)
		return make_list_type(ctx.reg, elem)

	case ^parser.Dict_Expr:
		// Extract expected key/value types for contextual typing
		key_expected, val_expected := TYPE_UNKNOWN, TYPE_UNKNOWN
		if expected != TYPE_UNKNOWN {
			exp_t := get_type(ctx.reg, expected)
			#partial switch exp_info in exp_t.info {
			case Dict_Type:
				key_expected = exp_info.key
				val_expected = exp_info.value
			case TypedDict_Type:
				key_expected = TYPE_STR
				val_expected = TYPE_ANY
			}
		}
		// Dict literal with **unpacking against TypedDict target: be permissive
		// {**td, "key": val} is the standard TypedDict update pattern
		has_unpack := false
		for k in e.keys {
			if k == nil { has_unpack = true; break }
		}
		if has_unpack && expected != TYPE_UNKNOWN {
			exp_t := get_type(ctx.reg, expected)
			#partial switch _ in exp_t.info {
			case TypedDict_Type:
				// Infer all values for side effects, return expected TypedDict
				for v in e.values { infer_expr(v, ctx) }
				return expected
			}
		}
		if len(e.keys) == 0 {
			return make_dict_type(ctx.reg, key_expected, val_expected)
		}
		key_types := make([dynamic]Type_ID, 0, len(e.keys), ctx.reg.allocator)
		val_types := make([dynamic]Type_ID, 0, len(e.values), ctx.reg.allocator)
		keys_match := key_expected != TYPE_UNKNOWN
		vals_match := val_expected != TYPE_UNKNOWN
		for k in e.keys {
			kt := infer_expr(k, ctx, key_expected)
			append(&key_types, kt)
			if keys_match && !is_assignable(ctx.reg, kt, key_expected) {
				keys_match = false
			}
		}
		for v in e.values {
			vt := infer_expr(v, ctx, val_expected)
			append(&val_types, vt)
			if vals_match && !is_assignable(ctx.reg, vt, val_expected) {
				vals_match = false
			}
		}
		key := key_expected if keys_match else unify_types(key_types[:], ctx.reg)
		val := val_expected if vals_match else unify_types(val_types[:], ctx.reg)
		return make_dict_type(ctx.reg, key, val)

	case ^parser.Set_Expr:
		// Extract expected element type for contextual typing
		elem_expected := TYPE_UNKNOWN
		if expected != TYPE_UNKNOWN {
			exp_t := get_type(ctx.reg, expected)
			#partial switch exp_info in exp_t.info {
			case Set_Type:
				elem_expected = exp_info.element
			}
		}
		if len(e.elts) == 0 {
			if elem_expected != TYPE_UNKNOWN {
				return make_set_type(ctx.reg, elem_expected)
			}
			return make_set_type(ctx.reg, TYPE_UNKNOWN)
		}
		elem_types := make([dynamic]Type_ID, 0, len(e.elts), ctx.reg.allocator)
		all_match := elem_expected != TYPE_UNKNOWN
		for elt in e.elts {
			et := infer_expr(elt, ctx, elem_expected)
			append(&elem_types, et)
			if all_match && !is_assignable(ctx.reg, et, elem_expected) {
				all_match = false
			}
		}
		if all_match {
			return make_set_type(ctx.reg, elem_expected)
		}
		elem := unify_types(elem_types[:], ctx.reg)
		return make_set_type(ctx.reg, elem)

	case ^parser.Tuple_Expr:
		elem_count := len(e.elts)
		tup_expected := make([]Type_ID, elem_count, ctx.reg.allocator)
		for i in 0..<elem_count { tup_expected[i] = TYPE_UNKNOWN }
		if expected != TYPE_UNKNOWN {
			exp_t := get_type(ctx.reg, expected)
			#partial switch exp_info in exp_t.info {
			case Tuple_Type:
				for i in 0..<min(elem_count, len(exp_info.elements)) {
					tup_expected[i] = exp_info.elements[i]
				}
			}
		}
		elem_types := make([]Type_ID, elem_count, ctx.reg.allocator)
		for elt, i in e.elts {
			elem_types[i] = infer_expr(elt, ctx, tup_expected[i])
		}
		return make_tuple_type(ctx.reg, elem_types, false)

	case ^parser.If_Expr:
		infer_expr(e.test, ctx)

		// Extract guards from test condition for ternary narrowing
		temp_guards := make([dynamic]flow.Guard, 0, 4, ctx.reg.allocator)
		TERNARY_TRUE  := flow.Block_ID(max(u32))
		TERNARY_FALSE := flow.Block_ID(max(u32) - 1)
		flow.analyze_condition(e.test, ctx.bind_result, ctx.scope_id,
			flow.Block_ID(0), TERNARY_TRUE, TERNARY_FALSE,
			e.loc, &temp_guards, ctx.reg.allocator)

		if len(temp_guards) > 0 {
			// Save env state
			saved := make(map[binder.Symbol_ID]Type_ID, len(ctx.env.types), ctx.reg.allocator)
			for k, v in ctx.env.types { saved[k] = v }
			saved_attr: map[u64]Type_ID
			if ctx.env.attr_types != nil {
				saved_attr = make(map[u64]Type_ID, len(ctx.env.attr_types), ctx.reg.allocator)
				for k, v in ctx.env.attr_types { saved_attr[k] = v }
			}

			// Apply positive guards → infer body (true branch)
			apply_guards(ctx.env, TERNARY_TRUE, temp_guards[:], ctx.reg, ctx.bind_result, ctx.builtins)
			body_type := infer_expr(e.body, ctx, expected)

			// Restore → apply negative guards → infer else (false branch)
			for k in ctx.env.types { delete_key(&ctx.env.types, k) }
			for k, v in saved { ctx.env.types[k] = v }
			if ctx.env.attr_types != nil {
				for k in ctx.env.attr_types { delete_key(&ctx.env.attr_types, k) }
			}
			if saved_attr != nil {
				if ctx.env.attr_types == nil {
					ctx.env.attr_types = make(map[u64]Type_ID, 4, ctx.reg.allocator)
				}
				for k, v in saved_attr { ctx.env.attr_types[k] = v }
			}
			apply_guards(ctx.env, TERNARY_FALSE, temp_guards[:], ctx.reg, ctx.bind_result, ctx.builtins)
			else_type := infer_expr(e.orelse, ctx, expected)

			// Restore original env
			for k in ctx.env.types { delete_key(&ctx.env.types, k) }
			for k, v in saved { ctx.env.types[k] = v }
			if ctx.env.attr_types != nil {
				for k in ctx.env.attr_types { delete_key(&ctx.env.attr_types, k) }
			}
			if saved_attr != nil {
				for k, v in saved_attr { ctx.env.attr_types[k] = v }
			}

			members := [2]Type_ID{body_type, else_type}
			return make_union_type(ctx.reg, members[:])
		}

		body_type := infer_expr(e.body, ctx, expected)
		else_type := infer_expr(e.orelse, ctx, expected)
		members := [2]Type_ID{body_type, else_type}
		return make_union_type(ctx.reg, members[:])

	case ^parser.Lambda_Expr:
		// Build callable type from lambda
		param_types := resolve_params(&e.args, ctx)
		body_type := infer_expr(e.body, ctx)
		return make_callable_type(ctx.reg, param_types, body_type)

	case ^parser.Starred_Expr:
		return infer_expr(e.value, ctx)

	case ^parser.Named_Expr:
		// walrus operator: x := expr
		val_type := infer_expr(e.value, ctx)
		// Assign to target
		assign_expr_type(e.target, val_type, ctx)
		return val_type

	case ^parser.Await_Expr:
		val_type := infer_expr(e.value, ctx)
		// If the awaited value is a Callable (coroutine), unwrap to its return type
		vt := get_type(ctx.reg, val_type)
		if ct, ok := vt.info.(Callable_Type); ok {
			return ct.return_type
		}
		return val_type

	case ^parser.Yield_Expr:
		yield_type := TYPE_NONE
		if e.value != nil {
			yield_type = infer_expr(e.value, ctx)
		}
		// Generator[Y, S, R]: yield expression returns SendType (S), not YieldType
		if ctx.generator_send_types != nil {
			if send_type, has := ctx.generator_send_types[ctx.scope_id]; has && send_type != TYPE_UNKNOWN {
				return send_type
			}
		}
		return yield_type

	case ^parser.Yield_From_Expr:
		return infer_expr(e.value, ctx)

	case ^parser.List_Comp:
		infer_comprehension_vars(e.generators, ctx)
		elem := infer_expr(e.elt, ctx)
		return make_list_type(ctx.reg, elem)
	case ^parser.Set_Comp:
		infer_comprehension_vars(e.generators, ctx)
		elem := infer_expr(e.elt, ctx)
		return make_set_type(ctx.reg, elem)
	case ^parser.Dict_Comp:
		infer_comprehension_vars(e.generators, ctx)
		key := infer_expr(e.key, ctx)
		val := infer_expr(e.value, ctx)
		return make_dict_type(ctx.reg, key, val)
	case ^parser.Generator_Expr:
		infer_comprehension_vars(e.generators, ctx)
		return infer_expr(e.elt, ctx)

	case ^parser.Formatted_Value:
		return TYPE_STR
	case ^parser.Joined_Str:
		return TYPE_STR

	case ^parser.Slice_Expr:
		// Bare slice object (1:3) — type inferred at Subscript_Expr level
		return TYPE_ANY
	}

	return TYPE_UNKNOWN
}

// ==================== Constant Inference ====================

infer_constant :: proc(e: ^parser.Constant_Expr, reg: ^Type_Registry = nil, expected: Type_ID = TYPE_UNKNOWN) -> Type_ID {
	// When expected type contains Literal types, produce Literal type for exact match
	if reg != nil && expected != TYPE_UNKNOWN && expected != TYPE_ANY {
		if _expected_has_literal(reg, expected) {
			#partial switch v in e.value {
			case i64:    return register_type(reg, Literal_Int_Type{value = v})
			case string: return register_type(reg, Literal_Str_Type{value = v})
			case bool:   return register_type(reg, Literal_Bool_Type{value = v})
			}
		}
	}
	switch v in e.value {
	case parser.Const_None:     return TYPE_NONE
	case parser.Const_Ellipsis: return TYPE_ANY
	case bool:                  return TYPE_BOOL
	case i64:                   return TYPE_INT
	case f64:                   return TYPE_FLOAT
	case parser.Const_Complex:  return TYPE_COMPLEX
	case string:                return TYPE_STR
	case parser.Const_Bytes:    return TYPE_BYTES
	}
	return TYPE_UNKNOWN
}

// Check if a type contains Literal types (directly or as union members)
_expected_has_literal :: proc(reg: ^Type_Registry, t: Type_ID) -> bool {
	ti := get_type(reg, t)
	#partial switch info in ti.info {
	case Literal_Int_Type, Literal_Str_Type, Literal_Bool_Type:
		return true
	case Union_Type:
		for m in info.members {
			if _expected_has_literal(reg, m) { return true }
		}
	}
	return false
}

// ==================== Name Inference ====================

infer_name :: proc(e: ^parser.Name_Expr, ctx: ^Infer_Context) -> Type_ID {
	// Look up in binder refs
	if sym_id, ok := binder.get_ref(ctx.bind_result, rawptr(e)); ok {
		// Check environment first (flow-sensitive)
		if t, found := ctx.env.types[sym_id]; found {
			return t
		}
		// Fallback: check class_types — qualified key, no collision
		if class_type, found := ctx.reg.class_types[qualify(ctx.reg, sym_id)]; found {
			return class_type
		}
		// Fallback: check module-level symbol types (LEGB "G" — global scope)
		// Only for functions/classes — variables may have stale flow-sensitive types
		if ctx.global_types != nil {
			if t, found := ctx.global_types[sym_id]; found {
				gt := get_type(ctx.reg, t)
				#partial switch _ in gt.info {
				case Callable_Type, Class_Type:
					return t
				}
			}
		}
	}
	// Check builtins
	if tid, ok := ctx.builtins.names[e.id]; ok {
		return tid
	}
	// Special constants
	switch e.id {
	case "True", "False": return TYPE_BOOL
	case "None":          return TYPE_NONE
	}
	return TYPE_UNKNOWN
}

// ==================== Binary Operator Inference ====================

infer_binop :: proc(op: parser.Binary_Op, left: Type_ID, right: Type_ID, reg: ^Type_Registry) -> Type_ID {
	// If either operand is unknown or any, be permissive
	if left == TYPE_UNKNOWN || left == TYPE_ANY { return TYPE_UNKNOWN }
	if right == TYPE_UNKNOWN || right == TYPE_ANY { return TYPE_UNKNOWN }

	// Union dispatch: try each member, collect results
	left_t := get_type(reg, left)
	right_t := get_type(reg, right)
	if lu, lu_ok := left_t.info.(Union_Type); lu_ok {
		results := make([dynamic]Type_ID, 0, len(lu.members), reg.allocator)
		for m in lu.members {
			r := infer_binop(op, m, right, reg)
			if r != TYPE_UNKNOWN {
				append(&results, r)
			}
		}
		if len(results) > 0 {
			if len(results) == 1 { return results[0] }
			return make_union_type(reg, results[:])
		}
	} else if ru, ru_ok := right_t.info.(Union_Type); ru_ok {
		results := make([dynamic]Type_ID, 0, len(ru.members), reg.allocator)
		for m in ru.members {
			r := infer_binop(op, left, m, reg)
			if r != TYPE_UNKNOWN {
				append(&results, r)
			}
		}
		if len(results) > 0 {
			if len(results) == 1 { return results[0] }
			return make_union_type(reg, results[:])
		}
	}

	// Helper: int or bool (Python promotes bool to int in arithmetic)
	left_intlike := left == TYPE_INT || left == TYPE_BOOL
	right_intlike := right == TYPE_INT || right == TYPE_BOOL

	switch op {
	case .Add:
		if left_intlike && right_intlike { return TYPE_INT }
		if is_numeric(reg, left) && is_numeric(reg, right) { return TYPE_FLOAT }
		if left == TYPE_STR && right == TYPE_STR { return TYPE_STR }
		if left == TYPE_BYTES && right == TYPE_BYTES { return TYPE_BYTES }
		if is_list_type(reg, left) && is_list_type(reg, right) { return left }
		// Tuple concatenation: tuple + tuple → tuple
		if is_tuple_type(reg, left) && is_tuple_type(reg, right) { return left }

	case .Sub, .Mult:
		if left_intlike && right_intlike { return TYPE_INT }
		if is_numeric(reg, left) && is_numeric(reg, right) { return TYPE_FLOAT }
		// str * int or int * str
		if op == .Mult {
			if left == TYPE_STR && right_intlike { return TYPE_STR }
			if left_intlike && right == TYPE_STR { return TYPE_STR }
			// bytes * int or int * bytes
			if left == TYPE_BYTES && right_intlike { return TYPE_BYTES }
			if left_intlike && right == TYPE_BYTES { return TYPE_BYTES }
			// list * int or int * list
			if is_list_type(reg, left) && right_intlike { return left }
			if left_intlike && is_list_type(reg, right) { return right }
			// tuple * int or int * tuple
			if is_tuple_type(reg, left) && right_intlike { return left }
			if left_intlike && is_tuple_type(reg, right) { return right }
		}

	case .Div:
		if is_numeric(reg, left) && is_numeric(reg, right) { return TYPE_FLOAT }

	case .Floor_Div:
		if left_intlike && right_intlike { return TYPE_INT }
		if is_numeric(reg, left) && is_numeric(reg, right) { return TYPE_FLOAT }

	case .Mod:
		if left_intlike && right_intlike { return TYPE_INT }
		if is_numeric(reg, left) && is_numeric(reg, right) { return TYPE_FLOAT }
		// str % (...) → str (printf-style formatting)
		if left == TYPE_STR { return TYPE_STR }
		// bytes % (...) → bytes (printf-style formatting)
		if left == TYPE_BYTES { return TYPE_BYTES }

	case .Pow:
		if left_intlike && right_intlike { return TYPE_INT }
		if is_numeric(reg, left) && is_numeric(reg, right) { return TYPE_FLOAT }

	case .LShift, .RShift, .Bit_And, .Bit_Xor:
		if left_intlike && right_intlike { return TYPE_INT }

	case .Bit_Or:
		if left_intlike && right_intlike { return TYPE_INT }
		if is_set_type(reg, left) && is_set_type(reg, right) { return left }
		// Dict/TypedDict merge: d1 | d2 → merged dict/TypedDict
		{
			lt := get_type(reg, left)
			rt := get_type(reg, right)
			l_is_dict := false; r_is_dict := false
			if _, ok := lt.info.(TypedDict_Type); ok { l_is_dict = true }
			if _, ok := lt.info.(Dict_Type); ok { l_is_dict = true }
			if _, ok := rt.info.(TypedDict_Type); ok { r_is_dict = true }
			if _, ok := rt.info.(Dict_Type); ok { r_is_dict = true }
			if l_is_dict && r_is_dict { return left }
			if l_is_dict { return left }
			if r_is_dict { return right }
		}
		// PEP 604: int | str → Union[int, str] (type objects use | for unions)
		left_as_type := callable_to_primitive(left, reg)
		right_as_type := callable_to_primitive(right, reg)
		if left_as_type != TYPE_UNKNOWN && right_as_type != TYPE_UNKNOWN {
			members := [2]Type_ID{left_as_type, right_as_type}
			return make_union_type(reg, members[:])
		}

	case .Mat_Mult:
		// Tensor @ Tensor → Tensor (shape validated in shape pass)
		lt := get_type(reg, left)
		rt := get_type(reg, right)
		if _, l_ok := lt.info.(Tensor_Type); l_ok {
			if _, r_ok := rt.info.(Tensor_Type); r_ok {
				return left // Shape pass validates dims; return left's type for now
			}
		}
		return TYPE_UNKNOWN
	}

	// Tensor elementwise ops: Tensor + Tensor → Tensor
	lt := get_type(reg, left)
	rt := get_type(reg, right)
	if l_tensor, l_ok := lt.info.(Tensor_Type); l_ok {
		if _, r_ok := rt.info.(Tensor_Type); r_ok {
			// Elementwise: broadcast shape computed in shape pass, return left's element type
			return make_tensor_type(reg, l_tensor.element_type, {})
		}
	}

	// Dunder method dispatch: try __add__/__radd__ etc. on Instance/Class types
	dunder := _binop_dunder(op)
	rdunder := _binop_rdunder(op)
	if dunder != "" {
		// Try left.__add__(right)
		method_type := lookup_attribute(left, dunder, reg)
		if method_type != TYPE_UNKNOWN {
			mt := get_type(reg, method_type)
			if ct, ok := mt.info.(Callable_Type); ok {
				return ct.return_type
			}
		}
		// Try right.__radd__(left)
		if rdunder != "" {
			rmethod_type := lookup_attribute(right, rdunder, reg)
			if rmethod_type != TYPE_UNKNOWN {
				rmt := get_type(reg, rmethod_type)
				if ct, ok := rmt.info.(Callable_Type); ok {
					return ct.return_type
				}
			}
		}
	}

	return TYPE_UNKNOWN // signals unsupported
}

// Map binary operators to their forward dunder method name
_binop_dunder :: proc(op: parser.Binary_Op) -> string {
	switch op {
	case .Add: return "__add__"
	case .Sub: return "__sub__"
	case .Mult: return "__mul__"
	case .Div: return "__truediv__"
	case .Floor_Div: return "__floordiv__"
	case .Mod: return "__mod__"
	case .Pow: return "__pow__"
	case .LShift: return "__lshift__"
	case .RShift: return "__rshift__"
	case .Bit_Or: return "__or__"
	case .Bit_Xor: return "__xor__"
	case .Bit_And: return "__and__"
	case .Mat_Mult: return "__matmul__"
	}
	return ""
}

// Map binary operators to their in-place dunder method name (for augmented assignment)
_augassign_dunder :: proc(op: parser.Binary_Op) -> string {
	switch op {
	case .Add: return "__iadd__"
	case .Sub: return "__isub__"
	case .Mult: return "__imul__"
	case .Div: return "__itruediv__"
	case .Floor_Div: return "__ifloordiv__"
	case .Mod: return "__imod__"
	case .Pow: return "__ipow__"
	case .LShift: return "__ilshift__"
	case .RShift: return "__irshift__"
	case .Bit_Or: return "__ior__"
	case .Bit_Xor: return "__ixor__"
	case .Bit_And: return "__iand__"
	case .Mat_Mult: return "__imatmul__"
	}
	return ""
}

// Map binary operators to their reverse dunder method name
_binop_rdunder :: proc(op: parser.Binary_Op) -> string {
	switch op {
	case .Add: return "__radd__"
	case .Sub: return "__rsub__"
	case .Mult: return "__rmul__"
	case .Div: return "__rtruediv__"
	case .Floor_Div: return "__rfloordiv__"
	case .Mod: return "__rmod__"
	case .Pow: return "__rpow__"
	case .LShift: return "__rlshift__"
	case .RShift: return "__rrshift__"
	case .Bit_Or: return "__ror__"
	case .Bit_Xor: return "__rxor__"
	case .Bit_And: return "__rand__"
	case .Mat_Mult: return "__rmatmul__"
	}
	return ""
}

// PEP 604: Map builtin constructor Callable_Types back to their primitive types.
// int() → TYPE_INT, str() → TYPE_STR, etc. Also handles Class_Type references.
callable_to_primitive :: proc(type_id: Type_ID, reg: ^Type_Registry) -> Type_ID {
	// None is a valid union member: None | int = Optional[int]
	if type_id == TYPE_NONE { return TYPE_NONE }
	t := get_type(reg, type_id)
	#partial switch info in t.info {
	case Callable_Type:
		// Builtin constructors: return_type IS the primitive
		if info.return_type != TYPE_UNKNOWN && info.return_type != TYPE_ANY {
			return info.return_type
		}
	case Class_Type:
		// Direct class reference: int | str where operand resolved to class
		return make_instance_type(reg, type_id)
	case Union_Type:
		// Chained PEP 604: (int | str) | None — left is already a union
		return type_id
	}
	return TYPE_UNKNOWN
}

// ==================== Unary Operator Inference ====================

infer_unaryop :: proc(op: parser.Unary_Op, operand: Type_ID, reg: ^Type_Registry) -> Type_ID {
	if operand == TYPE_UNKNOWN || operand == TYPE_ANY { return TYPE_UNKNOWN }

	switch op {
	case .USub, .UAdd:
		if operand == TYPE_INT { return TYPE_INT }
		if operand == TYPE_FLOAT { return TYPE_FLOAT }
		if operand == TYPE_BOOL { return TYPE_INT }
		if is_numeric(reg, operand) { return operand }
	case .Invert:
		if operand == TYPE_INT || operand == TYPE_BOOL { return TYPE_INT }
	case .Not:
		return TYPE_BOOL
	}
	return TYPE_UNKNOWN
}

// ==================== Call Inference ====================

infer_call :: proc(e: ^parser.Call_Expr, ctx: ^Infer_Context, expected: Type_ID = TYPE_UNKNOWN) -> Type_ID {
	// Check for typing special forms before normal dispatch
	if typing_result, handled := try_typing_call(e, ctx); handled {
		return typing_result
	}

	// DataFrame/GroupBy method intercepts — column-aware return types
	if attr_expr, attr_ok := e.func.(^parser.Attribute_Expr); attr_ok {
		recv_type := infer_expr(attr_expr.value, ctx)
		recv_t := get_type(ctx.reg, recv_type)
		if recv_t != nil {
			#partial switch recv_info in recv_t.info {
			case DataFrame_Type:
				// df.merge(right, on="key") → combined columns
				if attr_expr.attr == "merge" && len(e.args) >= 1 {
					right_type := infer_expr(e.args[0], ctx)
					join_key := ""
					for kw in e.keywords {
						if kw.arg == "on" {
							if c, c_ok := kw.value.(^parser.Constant_Expr); c_ok {
								if ks, ks_ok := c.value.(string); ks_ok {
									join_key = ks
								}
							}
						}
					}
					// Also check positional "on" arg (2nd arg)
					if join_key == "" && len(e.args) >= 2 {
						if c, c_ok := e.args[1].(^parser.Constant_Expr); c_ok {
							if ks, ks_ok := c.value.(string); ks_ok {
								join_key = ks
							}
						}
					}
					return compute_merge_result(ctx.reg, recv_type, right_type, join_key)
				}
				// df.rename(columns={"old": "new"}) → updated column names
				if attr_expr.attr == "rename" {
					for kw in e.keywords {
						if kw.arg == "columns" {
							if dict_lit, d_ok := kw.value.(^parser.Dict_Expr); d_ok {
								rename_map := make(map[string]string, len(dict_lit.keys), context.temp_allocator)
								for key, i in dict_lit.keys {
									if key == nil { continue }
									if kc, kc_ok := key.(^parser.Constant_Expr); kc_ok {
										if old_name, on_ok := kc.value.(string); on_ok {
											if vc, vc_ok := dict_lit.values[i].(^parser.Constant_Expr); vc_ok {
												if new_name, nn_ok := vc.value.(string); nn_ok {
													rename_map[old_name] = new_name
												}
											}
										}
									}
								}
								if len(rename_map) > 0 {
									return compute_rename_result(ctx.reg, recv_type, rename_map)
								}
							}
						}
					}
				}
			case Instance_Type:
				// GroupBy method intercept: grouped.sum()/mean()/etc. → column-aware DataFrame
				if ctx.reg.data_groupby_class != 0 && recv_info.class_type == ctx.reg.data_groupby_class {
					agg_name := attr_expr.attr
					if agg_name == "sum" || agg_name == "mean" || agg_name == "min" ||
					   agg_name == "max" || agg_name == "count" || agg_name == "std" {
						// Path 1: named receiver — grouped = df.groupby("k"); grouped.sum()
						if recv_name, rn_ok := attr_expr.value.(^parser.Name_Expr); rn_ok {
							if recv_sym, rsym_ok := binder.get_ref(ctx.bind_result, rawptr(recv_name)); rsym_ok {
								if gb_info, gb_found := ctx.groupby_sources[recv_sym]; gb_found {
									return compute_groupby_result(ctx.reg, &gb_info, agg_name)
								}
							}
						}
						// Path 2: chained call — df.groupby("k").sum()
						if gb_call, gc_ok := attr_expr.value.(^parser.Call_Expr); gc_ok {
							if gb_attr, ga_ok := gb_call.func.(^parser.Attribute_Expr); ga_ok {
								if gb_attr.attr == "groupby" && len(gb_call.args) >= 1 {
									// Get receiver's DataFrame type
									gb_recv_type := infer_expr(gb_attr.value, ctx)
									gb_recv_t := get_type(ctx.reg, gb_recv_type)
									if gb_recv_t != nil {
										#partial switch _ in gb_recv_t.info {
										case DataFrame_Type:
											if c, c_ok := gb_call.args[0].(^parser.Constant_Expr); c_ok {
												if key_str, ks_ok := c.value.(string); ks_ok {
													gb_info := GroupBy_Info{
														df_type   = gb_recv_type,
														group_key = key_str,
													}
													return compute_groupby_result(ctx.reg, &gb_info, agg_name)
												}
											}
										}
									}
								}
							}
						}
					}
				}
			}
		}
	}

	// super() or super(Cls, self) → Instance with merged attrs from all base classes (MRO)
	if name_expr, ok := e.func.(^parser.Name_Expr); ok && name_expr.id == "super" && (len(e.args) == 0 || len(e.args) == 2) && len(e.keywords) == 0 {
		if ctx.current_class != INVALID_TYPE {
			cls := get_type(ctx.reg, ctx.current_class)
			#partial switch cls_info in cls.info {
			case Class_Type:
				if len(cls_info.bases) == 1 {
					return make_instance_type(ctx.reg, cls_info.bases[0])
				}
				if len(cls_info.bases) > 1 {
					// Multiple inheritance: merge attrs from all bases
					merged := make(map[string]Type_ID, 16, ctx.reg.allocator)
					for base_id in cls_info.bases {
						bt := get_type(ctx.reg, base_id)
						if bci, ok := bt.info.(Class_Type); ok {
							for name, attr_type in bci.attrs {
								if name not_in merged { merged[name] = attr_type }
							}
						}
					}
					super_class := register_type(ctx.reg, Class_Type{
						name  = "super",
						attrs = merged,
						bases = cls_info.bases,
					})
					return make_instance_type(ctx.reg, super_class)
				}
			}
		}
		return TYPE_OBJECT
	}

	func_type := infer_expr(e.func, ctx)

	// object() constructor → TYPE_OBJECT. Only match the literal name "object",
	// not arbitrary expressions that resolve to TYPE_OBJECT (e.g., o() where o: object
	// after callable() guard, or cls() where cls: type[Self]).
	if func_type == TYPE_OBJECT {
		if name_expr, is_name := e.func.(^parser.Name_Expr); is_name && name_expr.id == "object" {
			for arg in e.args { infer_expr(arg, ctx) }
			return TYPE_OBJECT
		}
	}

	if func_type == TYPE_UNKNOWN || func_type == TYPE_ANY {
		// Still type-check args
		for arg in e.args {
			infer_expr(arg, ctx)
		}
		return TYPE_UNKNOWN
	}

	// Check for overloads — if function has @overload sigs, resolve against them
	#partial switch fn in e.func {
	case ^parser.Name_Expr:
		if sym_id, ok := binder.get_ref(ctx.bind_result, rawptr(fn)); ok {
			if sigs, has := ctx.reg.overload_sigs[sym_id]; has && len(sigs) > 0 {
				return resolve_overload(e, sigs[:], ctx)
			}
		}
	}

	ft := get_type(ctx.reg, func_type)
	#partial switch &info in ft.info {
	case Callable_Type:
		if callable_has_typevars(&info, ctx.reg) {
			return infer_generic_call(e, &info, ctx)
		}
		check_call_args(e, &info, ctx)

		// Builtin container-aware return type refinement:
		// min(list[T]) -> T, max(list[T]) -> T, sum(list[T]) -> T, sorted(list[T]) -> list[T]
		if len(e.args) >= 1 {
			if name_expr, is_name := e.func.(^parser.Name_Expr); is_name {
				arg_type := infer_expr(e.args[0], ctx)
				arg_t := get_type(ctx.reg, arg_type)
				elem_type := TYPE_UNKNOWN
				#partial switch ai in arg_t.info {
				case List_Type: elem_type = ai.element
				case Set_Type:  elem_type = ai.element
				case Tuple_Type:
					if len(ai.elements) > 0 { elem_type = ai.elements[0] }
				}
				if elem_type != TYPE_UNKNOWN {
					switch name_expr.id {
					case "min", "max":
						return elem_type
					case "sum":
						if elem_type == TYPE_FLOAT { return TYPE_FLOAT }
						return TYPE_INT
					case "sorted", "list":
						return make_list_type(ctx.reg, elem_type)
					case "reversed":
						return make_list_type(ctx.reg, elem_type)
					case "enumerate":
						// enumerate(Iterable[T]) → Iterator[tuple[int, T]]
						return make_list_type(ctx.reg, make_tuple_type(ctx.reg, {TYPE_INT, elem_type}, false))
					}
				}
				// zip(iter1, iter2) → list[tuple[T1, T2]]
				if name_expr.id == "zip" && len(e.args) >= 2 {
					elems := make([dynamic]Type_ID, 0, len(e.args), ctx.reg.allocator)
					for arg in e.args {
						at := infer_expr(arg, ctx)
						et := get_iterator_element_type(at, ctx.reg)
						append(&elems, et)
					}
					return make_list_type(ctx.reg, make_tuple_type(ctx.reg, elems[:], false))
				}
			}
		}

		// mimir.json typed parse/read — override return type with schema argument
		if ctx.reg.json_parse_type != 0 &&
		   (func_type == ctx.reg.json_parse_type || func_type == ctx.reg.json_read_type) {
			if len(e.args) >= 2 {
				schema_type := resolve_annotation(e.args[1], ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
				if schema_type != TYPE_UNKNOWN && schema_type != TYPE_ANY {
					st := get_type(ctx.reg, schema_type)
					if st != nil {
						#partial switch _ in st.info {
						case TypedDict_Type:
							check_json_schema_fields(ctx, schema_type, e.loc)
							return schema_type
						case Class_Type:
							return make_instance_type(ctx.reg, schema_type)
						case Instance_Type:
							return schema_type
						}
					}
					// JSON002: schema is not a TypedDict or class
					emit_diagnostic(ctx, e.loc, "JSON002", .Error,
						"Invalid JSON schema type",
						fmt.aprintf("Expected TypedDict or class, got '%s'",
							type_to_string(ctx.reg, schema_type),
							allocator = ctx.reg.allocator),
						"Use a TypedDict as the schema argument")
				}
			}
			return info.return_type
		}
		// mimir.data typed read — override return type with schema argument
		if ctx.reg.data_read_csv_type != 0 &&
		   (func_type == ctx.reg.data_read_csv_type ||
		    func_type == ctx.reg.data_read_json_type ||
		    func_type == ctx.reg.data_read_parquet_type) {
			if len(e.args) >= 2 {
				schema_type := resolve_annotation(e.args[1], ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
				if schema_type != TYPE_UNKNOWN && schema_type != TYPE_ANY {
					st := get_type(ctx.reg, schema_type)
					if st != nil {
						#partial switch td_info in st.info {
						case TypedDict_Type:
							return make_dataframe_type(ctx.reg, td_info.fields)
						}
					}
					emit_diagnostic(ctx, e.loc, "DATA002", .Error,
						"Invalid DataFrame schema type",
						fmt.aprintf("Expected TypedDict schema, got '%s'",
							type_to_string(ctx.reg, schema_type),
							allocator = ctx.reg.allocator),
						"Use a TypedDict as the schema argument")
				}
			}
			// No schema → unknown columns DataFrame
			return make_dataframe_type(ctx.reg, {})
		}
		// mimir.data.DataFrame constructor — infer columns from dict literal
		if ctx.reg.data_dataframe_type != 0 && func_type == ctx.reg.data_dataframe_type {
			if len(e.args) >= 1 {
				if dict_lit, ok := e.args[0].(^parser.Dict_Expr); ok {
					return infer_dataframe_from_dict(ctx, dict_lit)
				}
			}
			return make_dataframe_type(ctx.reg, {})
		}
		// mimir.db typed query — override return type with result= keyword schema
		if ctx.reg.db_query_type != 0 &&
		   (func_type == ctx.reg.db_query_type || func_type == ctx.reg.db_conn_query_type) {
			for kw in e.keywords {
				if kw.arg == "result" {
					schema_type := resolve_annotation(kw.value, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
					if schema_type != TYPE_UNKNOWN && schema_type != TYPE_ANY {
						st := get_type(ctx.reg, schema_type)
						if st != nil {
							#partial switch _ in st.info {
							case TypedDict_Type:
								return make_list_type(ctx.reg, schema_type)
							case Class_Type:
								return make_list_type(ctx.reg, make_instance_type(ctx.reg, schema_type))
							case Instance_Type:
								return make_list_type(ctx.reg, schema_type)
							}
						}
						// DB002: result is not a TypedDict or class
						emit_diagnostic(ctx, e.loc, "DB002", .Error,
							"Invalid query result schema",
							fmt.aprintf("Expected TypedDict or class, got '%s'",
								type_to_string(ctx.reg, schema_type),
								allocator = ctx.reg.allocator),
							"Use a TypedDict as the result argument")
					}
					break
				}
			}
			return info.return_type
		}
		// mimir.actor spawn — infer ActorRef message type from actor class's on_receive
		if ctx.reg.actor_spawn_type != 0 &&
		   (func_type == ctx.reg.actor_spawn_type || func_type == ctx.reg.actor_system_spawn_type) {
			if len(e.args) >= 1 {
				arg_type := infer_expr(e.args[0], ctx)
				is_class := false
				at := get_type(ctx.reg, arg_type)
				if at != nil {
					#partial switch class_info in at.info {
					case Class_Type:
						is_class = true
						// Look for on_receive method to extract message/return types
						if on_recv, has := class_info.attrs["on_receive"]; has {
							rt := get_type(ctx.reg, on_recv)
							if rt != nil {
								#partial switch recv_info in rt.info {
								case Callable_Type:
									msg_type := TYPE_ANY
									ret_type := TYPE_ANY
									if len(recv_info.params) > 0 {
										msg_type = recv_info.params[0].type_id
									}
									if recv_info.return_type != TYPE_UNKNOWN {
										ret_type = recv_info.return_type
									}
									// Build specialized ActorRef with concrete send/ask types
									if msg_type != TYPE_ANY || ret_type != TYPE_ANY {
										cache_key := [2]Type_ID{msg_type, ret_type}
										if cached, found := ctx.reg.actor_ref_cache[cache_key]; found {
											return cached
										}
										ref_attrs := make(map[string]Type_ID, 4, ctx.reg.allocator)
										ref_attrs["send"] = make_callable_type(ctx.reg,
											{Param_Type{name = "message", type_id = msg_type}},
											TYPE_NONE,
										)
										ref_attrs["ask"] = make_callable_type(ctx.reg,
											{
												Param_Type{name = "message", type_id = msg_type},
												Param_Type{name = "timeout", type_id = TYPE_FLOAT, has_default = true},
											},
											ret_type,
										)
										ref_attrs["stop"] = make_callable_type(ctx.reg, {}, TYPE_NONE)
										ref_attrs["is_alive"] = make_callable_type(ctx.reg, {}, TYPE_BOOL)
										spec_class := register_type(ctx.reg, Class_Type{
											name  = "ActorRef",
											attrs = ref_attrs,
										})
										spec_instance := make_instance_type(ctx.reg, spec_class)
										ctx.reg.actor_ref_cache[cache_key] = spec_instance
										return spec_instance
									}
								}
							}
						}
					}
				}
				if !is_class && arg_type != TYPE_UNKNOWN && arg_type != TYPE_ANY {
					emit_diagnostic(ctx, e.loc, "T002", .Error,
						"spawn() requires an Actor subclass",
						fmt.aprintf("Expected an Actor class, got '%s'",
							type_to_string(ctx.reg, arg_type),
							allocator = ctx.reg.allocator),
						"Pass a class that inherits from Actor")
				}
			}
			return info.return_type
		}
		// Shape-aware tensor return: if this is a mimir.array function, compute shaped result
		if ctx.shape_reg != nil {
			if shaped := infer_shaped_return(e, info.return_type, ctx); shaped != TYPE_UNKNOWN {
				return shaped
			}
		}
		return info.return_type

	case TypedDict_Type:
		// TypedDict constructor — validate keyword args against fields
		for arg in e.args { infer_expr(arg, ctx) }
		for kw in e.keywords {
			if kw.arg == "" { continue } // **kwargs unpacking
			kw_type := infer_expr(kw.value, ctx)
			if field_type, ok := info.fields[kw.arg]; ok {
				if kw_type != TYPE_UNKNOWN && kw_type != TYPE_ANY &&
				   field_type != TYPE_UNKNOWN && field_type != TYPE_ANY {
					if !is_assignable(ctx.reg, kw_type, field_type) {
						emit_diagnostic(ctx, e.loc, "T002", .Error,
							"Incompatible TypedDict field type",
							fmt_type_mismatch(kw_type, field_type, ctx.reg),
							"Use the correct type")
					}
				}
			} else {
				// Extra keyword not in TypedDict fields
				td_display := info.name if len(info.name) > 0 else "TypedDict"
				emit_diagnostic(ctx, e.loc, "T004", .Error,
					"Extra TypedDict field",
					fmt.aprintf("TypedDict '%s' has no field '%s'", td_display, kw.arg,
						allocator = ctx.reg.allocator),
					"Remove the extra field or add it to the TypedDict definition")
			}
		}
		// Check for missing required fields (per-field Required/NotRequired)
		// Skip when positional args present (dict literal/call) or **kwargs unpacking
		has_kwargs_unpack := false
		for kw in e.keywords {
			if kw.arg == "" { has_kwargs_unpack = true; break }
		}
		if len(e.args) == 0 && !has_kwargs_unpack {
			provided := make(map[string]bool, len(e.keywords), ctx.reg.allocator)
			for kw in e.keywords {
				provided[kw.arg] = true
			}
			for field_name in info.fields {
				if field_name in provided { continue }
				// Determine if field is required
				is_required := info.total // default based on total=
				if req_val, has_req := info.required_fields[field_name]; has_req {
					is_required = req_val
				}
				if is_required {
					emit_diagnostic(ctx, e.loc, "T004", .Error,
						"Missing required TypedDict field",
						fmt.aprintf("Missing required field '%s'", field_name,
							allocator = ctx.reg.allocator),
						"Provide all required fields")
				}
			}
		}
		return func_type

	case Class_Type:
		// Check abstract class instantiation
		if len(info.abstract_methods) > 0 {
			names_dyn := make([dynamic]string, 0, len(info.abstract_methods), ctx.reg.allocator)
			for name, is_abstract in info.abstract_methods {
				if is_abstract { append(&names_dyn, name) }
			}
			if len(names_dyn) > 0 {
				emit_diagnostic(ctx, e.loc, "T013", .Error,
					"Cannot instantiate abstract class",
					fmt.tprintf("'%s' has unimplemented abstract method(s): %s",
						info.name, strings.join(names_dyn[:], ", ", allocator = ctx.reg.allocator)),
					"Implement all abstract methods in a concrete subclass")
			}
		}

		// Generic class — infer TypeVar bindings from __init__ args
		if len(info.type_params) > 0 {
			return infer_generic_constructor(e, &info, func_type, ctx, expected)
		}

		// Builtin container constructors: list(iterable) → list[T], etc.
		if len(e.args) >= 1 && (info.name == "list" || info.name == "dict" || info.name == "set" || info.name == "tuple" || info.name == "frozenset") {
			arg_type := infer_expr(e.args[0], ctx)
			arg_t := get_type(ctx.reg, arg_type)
			elem_type := TYPE_UNKNOWN
			#partial switch ai in arg_t.info {
			case List_Type: elem_type = ai.element
			case Set_Type:  elem_type = ai.element
			case Tuple_Type:
				if len(ai.elements) > 0 { elem_type = ai.elements[0] }
			}
			if elem_type != TYPE_UNKNOWN {
				switch info.name {
				case "list":      return make_list_type(ctx.reg, elem_type)
				case "set":       return make_set_type(ctx.reg, elem_type)
				case "frozenset": return make_set_type(ctx.reg, elem_type)
				case "tuple":     return make_tuple_type(ctx.reg, {elem_type}, true)
				}
			}
		}

		// defaultdict: all constructor args are optional (0-2 args valid)
		if info.name == "defaultdict" {
			for arg in e.args { infer_expr(arg, ctx) }
			return make_instance_type(ctx.reg, func_type)
		}

		// Enum functional form: Enum('Name', 'members', ...) uses metaclass constructor
		// The __init__ signature doesn't match; skip arg checking for enum class calls
		if info.is_enum || info.name == "Enum" || info.name == "IntEnum" ||
		   info.name == "Flag" || info.name == "IntFlag" || info.name == "StrEnum" {
			for arg in e.args { infer_expr(arg, ctx) }
			return make_instance_type(ctx.reg, func_type)
		}

		// Calling a class = constructor → check __new__ args (if defined), else __init__
		checked_constructor := false
		if new_type_id, new_ok := info.attrs["__new__"]; new_ok {
			new_t := get_type(ctx.reg, new_type_id)
			#partial switch &new_info in new_t.info {
			case Callable_Type:
				check_call_args(e, &new_info, ctx)
				checked_constructor = true
			}
		}
		if !checked_constructor {
			if init_type_id, ok := info.attrs["__init__"]; ok {
				init_t := get_type(ctx.reg, init_type_id)
				#partial switch &init_info in init_t.info {
				case Callable_Type:
					check_call_args(e, &init_info, ctx)
				case:
					for arg in e.args { infer_expr(arg, ctx) }
				}
			} else {
				for arg in e.args { infer_expr(arg, ctx) }
			}
		}
		return make_instance_type(ctx.reg, func_type)
	}

	// Not callable — emit T005 for known non-callable types
	is_noncallable := false
	switch func_type {
	case TYPE_NONE, TYPE_INT, TYPE_FLOAT, TYPE_BOOL, TYPE_BYTES, TYPE_STR:
		is_noncallable = true
	}
	if !is_noncallable {
		ft := get_type(ctx.reg, func_type)
		#partial switch nc_info in ft.info {
		case Instance_Type:
			cls := get_type(ctx.reg, nc_info.class_type)
			if cls_info, cls_ok := cls.info.(Class_Type); cls_ok {
				// Only flag if class has enough attrs to be confident
				if len(cls_info.attrs) > 3 && "__call__" not_in cls_info.attrs {
					is_noncallable = true
				}
			}
		case Module_Type:
			is_noncallable = true
		case Tuple_Type:
			is_noncallable = true
		case List_Type:
			is_noncallable = true
		case Dict_Type:
			is_noncallable = true
		case Set_Type:
			is_noncallable = true
		}
	}
	if is_noncallable {
		emit_diagnostic(ctx, e.loc, "T005", .Error,
			"Not callable",
			fmt.aprintf("'%s' is not callable",
				type_to_string(ctx.reg, func_type),
				allocator = ctx.reg.allocator),
			"Check variable type — it may need to be initialized differently")
	}
	for arg in e.args {
		infer_expr(arg, ctx)
	}
	return TYPE_UNKNOWN
}

check_call_args :: proc(e: ^parser.Call_Expr, func_info: ^Callable_Type, ctx: ^Infer_Context) {
	// Skip arg count checking if all params are TYPE_ANY (stub/unresolved function)
	// These are placeholder signatures from typeshed or unresolved imports — arg count is unknown
	if len(func_info.params) > 0 {
		all_any := true
		for p in func_info.params {
			if p.type_id != TYPE_ANY && !_is_any_type(p.type_id, ctx.reg) { all_any = false; break }
		}
		if all_any { return }
	}

	// Count required params (no default)
	required := 0
	for p in func_info.params {
		if !p.has_default { required += 1 }
	}

	// Detect unbound method call: X.method(instance, args) where X is a class
	// build_func_type strips self/cls for methods, so the caller provides an extra arg
	// that isn't reflected in func_info.params.
	// Only detect for __init__/__new__ (most common unbound patterns);
	// static/class methods don't have self stripped, so no adjustment needed.
	is_unbound := false
	if attr, ok := e.func.(^parser.Attribute_Expr); ok {
		receiver_type := infer_expr(attr.value, ctx)
		rt := get_type(ctx.reg, receiver_type)
		if _, is_class := rt.info.(Class_Type); is_class {
			if attr.attr == "__init__" || attr.attr == "__new__" {
				is_unbound = true
			}
		}
	}

	// Check arg count (positional + named keyword, excluding **kwargs and *args unpacking)
	n_args := len(e.args)
	n_named_kw := 0
	has_star_kwargs := false
	has_star_args := false
	// Try to expand *star_arg if it's a known-length tuple
	star_arg_idx := -1
	star_tuple_elems: []Type_ID
	for kw in e.keywords {
		if kw.arg == "" {
			has_star_kwargs = true
		} else {
			n_named_kw += 1
		}
	}
	for arg, idx in e.args {
		if star, is_starred := arg.(^parser.Starred_Expr); is_starred {
			star_type := infer_expr(star.value, ctx)
			st := get_type(ctx.reg, star_type)
			if tup, is_tuple := st.info.(Tuple_Type); is_tuple && !tup.is_variadic && len(tup.elements) > 0 {
				// Known-length tuple: expand into positional args
				star_arg_idx = idx
				star_tuple_elems = tup.elements
				n_args += len(tup.elements) - 1  // -1 because *arg already counted as 1
			} else {
				has_star_args = true
			}
			break
		}
	}
	n_total := n_args + n_named_kw
	n_params := len(func_info.params)
	// Adjust for unbound method — self was already stripped by build_func_type,
	// but caller provides it explicitly. Subtract from n_total to account for the extra arg.
	unbound_offset := 0
	if is_unbound { n_total = max(n_total - 1, 0); unbound_offset = 1 }

	// Check if ANY param is variadic (*args or **kwargs) — not just the last
	has_variadic_param := false
	for p in func_info.params {
		if p.is_variadic { has_variadic_param = true; break }
	}

	// With *args/**kwargs unpacking, we can't statically determine the total arg count
	if !has_star_kwargs && !has_star_args {
		if n_total < required {
			emit_diagnostic(ctx, e.loc, "T004", .Error,
				"Too few arguments",
				fmt_arg_count_error(required, n_total, ctx.reg),
				"Add missing arguments")
		} else if n_total > n_params && !has_variadic_param {
			if n_params == 0 {
				// Skip for chained/higher-order calls: f(g)(args)
				// The inner call returns a callable with unresolved params
				is_chained := false
				if _, is_call := e.func.(^parser.Call_Expr); is_call { is_chained = true }
				if !is_chained {
					emit_diagnostic(ctx, e.loc, "T004", .Error,
						"Too many arguments",
						fmt_arg_count_error(n_params, n_total, ctx.reg),
						"Remove extra arguments")
				}
			} else {
				last := func_info.params[n_params - 1]
				if last.type_id != TYPE_ANY {
					emit_diagnostic(ctx, e.loc, "T004", .Error,
						"Too many arguments",
						fmt_arg_count_error(n_params, n_total, ctx.reg),
						"Remove extra arguments")
				}
			}
		}
	}

	// Check for duplicate positional + keyword arguments
	for kw in e.keywords {
		if kw.arg == "" { continue } // **kwargs unpacking
		for j := 0; j < min(n_args, n_params); j += 1 {
			if func_info.params[j].name == kw.arg {
				emit_diagnostic(ctx, e.loc, "T004", .Error,
					"Duplicate argument",
					fmt.tprintf("parameter '%s' already supplied as positional argument %d", kw.arg, j + 1),
					"Remove the duplicate keyword argument")
				break
			}
		}
	}

	// Check positional arg types against param types
	// For unbound calls, infer arg[0] (self) but don't type-check it against params
	if unbound_offset > 0 && n_args > 0 { infer_expr(e.args[0], ctx) }
	if star_arg_idx >= 0 && star_tuple_elems != nil {
		// Star-expanded: check args before star, tuple elements, then args after star
		param_idx := 0
		for i := 0 + unbound_offset; i < len(e.args); i += 1 {
			if i == star_arg_idx {
				// Expand tuple elements against params
				for elem in star_tuple_elems {
					if param_idx >= n_params { break }
					param_type := func_info.params[param_idx].type_id
					if !_is_any_type(param_type, ctx.reg) && param_type != TYPE_UNKNOWN &&
					   elem != TYPE_UNKNOWN && !_is_any_type(elem, ctx.reg) &&
					   !_union_has_unknown(elem, ctx.reg) {
						if !is_assignable(ctx.reg, elem, param_type) {
							emit_diagnostic(ctx, e.loc, "T002", .Error,
								"Incompatible argument type",
								fmt_type_mismatch(elem, param_type, ctx.reg),
								"Use the correct type")
						}
					}
					param_idx += 1
				}
			} else {
				if param_idx >= n_params { break }
				param_type := func_info.params[param_idx].type_id
				arg_type := infer_expr(e.args[i], ctx, param_type)
				if !_is_any_type(param_type, ctx.reg) && param_type != TYPE_UNKNOWN &&
				   arg_type != TYPE_UNKNOWN && !_is_any_type(arg_type, ctx.reg) &&
				   !_union_has_unknown(arg_type, ctx.reg) {
					if !is_assignable(ctx.reg, arg_type, param_type) {
						emit_diagnostic(ctx, e.loc, "T002", .Error,
							"Incompatible argument type",
							fmt_type_mismatch(arg_type, param_type, ctx.reg),
							"Use the correct type")
					}
				}
				param_idx += 1
			}
		}
	} else {
		arg_check_count := min(n_args - unbound_offset, n_params)
		for i := 0; i < arg_check_count; i += 1 {
			param_type := func_info.params[i].type_id
			arg := e.args[i + unbound_offset]
			// For *starred args: check element type, not container type
			is_starred := false
			if _, star_ok := arg.(^parser.Starred_Expr); star_ok { is_starred = true }
			arg_type := infer_expr(arg, ctx, param_type)
			if is_starred {
				// Extract element type from container: *list[T] → T, *tuple[T,...] → T
				at := get_type(ctx.reg, arg_type)
				#partial switch ai in at.info {
				case List_Type: arg_type = ai.element
				case Set_Type: arg_type = ai.element
				case Tuple_Type:
					if ai.is_variadic && len(ai.elements) == 1 {
						arg_type = ai.elements[0]
					} else if len(ai.elements) > 0 {
						arg_type = make_union_type(ctx.reg, ai.elements)
					}
				}
			}
			if _is_any_type(param_type, ctx.reg) || param_type == TYPE_UNKNOWN ||
			   arg_type == TYPE_UNKNOWN || _is_any_type(arg_type, ctx.reg) ||
			   _union_has_unknown(arg_type, ctx.reg) {
				// Skip — Any/Unknown in union means partial resolution, can't verify
			} else if !is_assignable(ctx.reg, arg_type, param_type) {
				emit_diagnostic(ctx, e.loc, "T002", .Error,
					"Incompatible argument type",
					fmt_type_mismatch(arg_type, param_type, ctx.reg),
					"Use the correct type")
			}
		}
	}

	// Check keyword arg types and names against matching param types
	for kw in e.keywords {
		if kw.arg == "" { continue } // **kwargs unpacking
		kw_type := infer_expr(kw.value, ctx)
		found_param := false
		for p in func_info.params {
			if p.name == kw.arg {
				found_param = true
				if _is_any_type(p.type_id, ctx.reg) || p.type_id == TYPE_UNKNOWN ||
				   kw_type == TYPE_UNKNOWN || _is_any_type(kw_type, ctx.reg) ||
				   _union_has_unknown(kw_type, ctx.reg) {
					// Skip
				} else if !is_assignable(ctx.reg, kw_type, p.type_id) {
					emit_diagnostic(ctx, e.loc, "T002", .Error,
						"Incompatible argument type",
						fmt_type_mismatch(kw_type, p.type_id, ctx.reg),
						"Use the correct type")
				}
				break
			}
			if p.is_variadic { found_param = true; break } // **kwargs accepts any keyword
		}
		if !found_param && !has_variadic_param && n_params >= 2 {
			// Only flag for locally-defined functions (not imports/stubs)
			// Imported functions may have incomplete signatures missing **kwargs
			is_local := false
			#partial switch fn in e.func {
			case ^parser.Name_Expr:
				if sym_id, sym_ok := binder.get_ref(ctx.bind_result, rawptr(fn)); sym_ok {
					sym := binder.result_get_symbol(ctx.bind_result, sym_id)
					if sym != nil && sym.kind == .Function { is_local = true }
				}
			}
			if is_local {
				emit_diagnostic(ctx, e.loc, "T004", .Error,
					"Unexpected keyword argument",
					fmt.tprintf("'%s' is not a valid keyword argument", kw.arg),
					"Check the function signature for valid parameter names")
			}
		}
	}

	// Check required keyword-only params are provided
	// Keyword-only params come after the *args param in the param list
	if !has_star_kwargs {
		saw_variadic := false
		for p in func_info.params {
			if p.is_variadic { saw_variadic = true; continue }
			if saw_variadic && !p.has_default {
				// This is a required keyword-only param — check if provided
				provided := false
				for kw in e.keywords {
					if kw.arg == p.name { provided = true; break }
				}
				if !provided {
					emit_diagnostic(ctx, e.loc, "T004", .Error,
						"Missing required keyword argument",
						fmt.tprintf("'%s' is a required keyword-only argument", p.name),
						"Add the missing keyword argument")
				}
			}
		}
	}

	// Type-check remaining positional args against *args type (if present)
	if n_params > 0 {
		last := func_info.params[n_params - 1]
		if last.is_variadic && !_is_any_type(last.type_id, ctx.reg) && last.type_id != TYPE_ANY && last.type_id != TYPE_UNKNOWN {
			// Check excess positional args against *args element type
			for i := n_params; i < n_args; i += 1 {
				arg_type := infer_expr(e.args[i], ctx, last.type_id)
				if arg_type == TYPE_UNKNOWN || _is_any_type(arg_type, ctx.reg) || _union_has_unknown(arg_type, ctx.reg) {
					// Skip
				} else if !is_assignable(ctx.reg, arg_type, last.type_id) {
					emit_diagnostic(ctx, e.loc, "T002", .Error,
						"Incompatible argument type",
						fmt_type_mismatch(arg_type, last.type_id, ctx.reg),
						"Use the correct type")
				}
			}
		} else {
			for i := n_params; i < n_args; i += 1 {
				infer_expr(e.args[i], ctx)
			}
		}
	} else {
		for i := n_params; i < n_args; i += 1 {
			infer_expr(e.args[i], ctx)
		}
	}
}

// ==================== Attribute Lookup ====================

// Helper to build param slices for method signatures
make_params :: proc(reg: ^Type_Registry, types: []Type_ID, defaults: []bool = {}) -> []Param_Type {
	ps := make([]Param_Type, len(types), reg.allocator)
	for t, i in types {
		ps[i] = Param_Type{name = "", type_id = t, has_default = i < len(defaults) && defaults[i]}
	}
	return ps
}

// Check if a class inherits from a dict-like base (Mapping, MutableMapping, dict).
@(private = "file")
_is_dunder :: proc(name: string) -> bool {
	return len(name) >= 4 && name[0] == '_' && name[1] == '_' &&
	       name[len(name)-1] == '_' && name[len(name)-2] == '_'
}

@(private = "file")
_has_mapping_base :: proc(reg: ^Type_Registry, cls: ^Class_Type) -> bool {
	for base_id in cls.bases {
		bt := get_type(reg, base_id)
		#partial switch bi in bt.info {
		case Class_Type:
			if bi.name == "Mapping" || bi.name == "MutableMapping" || bi.name == "dict" {
				return true
			}
		case Instance_Type:
			ct := get_type(reg, bi.class_type)
			#partial switch ci in ct.info {
			case Class_Type:
				if ci.name == "Mapping" || ci.name == "MutableMapping" || ci.name == "dict" {
					return true
				}
			}
		}
	}
	return false
}

// Return dict method types for Mapping/MutableMapping subclasses.
@(private = "file")
_lookup_dict_method :: proc(attr: string, reg: ^Type_Registry) -> Type_ID {
	no_params := make([]Param_Type, 0, reg.allocator)
	switch attr {
	case "get":
		return make_callable_type(reg, make_params(reg, {TYPE_STR, TYPE_ANY}, {false, true}), TYPE_ANY)
	case "pop":
		return make_callable_type(reg, make_params(reg, {TYPE_STR, TYPE_ANY}, {false, true}), TYPE_ANY)
	case "setdefault":
		return make_callable_type(reg, make_params(reg, {TYPE_STR, TYPE_ANY}, {false, true}), TYPE_ANY)
	case "keys":
		return make_callable_type(reg, no_params, TYPE_ANY)
	case "values":
		return make_callable_type(reg, no_params, TYPE_ANY)
	case "items":
		return make_callable_type(reg, no_params, TYPE_ANY)
	case "update":
		return make_callable_type(reg, make_params(reg, {TYPE_ANY}, {true}), TYPE_NONE)
	case "copy":
		return make_callable_type(reg, no_params, TYPE_ANY)
	case "__contains__":
		return make_callable_type(reg, make_params(reg, {TYPE_ANY}), TYPE_BOOL)
	case "__len__":
		return make_callable_type(reg, no_params, TYPE_INT)
	}
	return TYPE_UNKNOWN
}

lookup_attribute :: proc(receiver: Type_ID, attr: string, reg: ^Type_Registry) -> Type_ID {
	if receiver == TYPE_UNKNOWN || receiver == TYPE_ANY { return TYPE_UNKNOWN }

	no_params := make([]Param_Type, 0, reg.allocator)

	// String methods
	if receiver == TYPE_STR {
		switch attr {
		// 0-arg methods returning str
		case "upper", "lower", "title", "capitalize", "swapcase":
			return make_callable_type(reg, no_params, TYPE_STR)
		// 0-or-1-arg methods returning str (optional chars arg)
		case "strip", "lstrip", "rstrip":
			return make_callable_type(reg, make_params(reg, {TYPE_STR}, {true}), TYPE_STR)
		// 1+ arg methods returning str
		case "replace":
			return make_callable_type(reg,
				make_params(reg, {TYPE_STR, TYPE_STR, TYPE_INT}, {false, false, true}), TYPE_STR)
		case "join":
			return make_callable_type(reg, make_params(reg, {TYPE_ANY}), TYPE_STR)
		case "format":
			// format(*args, **kwargs) — accept any number via TYPE_ANY variadic
			return make_callable_type(reg, make_params(reg, {TYPE_ANY}, {true}), TYPE_STR)
		case "center", "ljust", "rjust":
			return make_callable_type(reg,
				make_params(reg, {TYPE_INT, TYPE_STR}, {false, true}), TYPE_STR)
		case "zfill":
			return make_callable_type(reg, make_params(reg, {TYPE_INT}), TYPE_STR)
		case "encode":
			return make_callable_type(reg,
				make_params(reg, {TYPE_STR, TYPE_STR}, {true, true}), TYPE_BYTES)
		// Methods returning list[str]
		case "split", "rsplit":
			return make_callable_type(reg,
				make_params(reg, {TYPE_STR, TYPE_INT}, {true, true}), make_list_type(reg, TYPE_STR))
		case "splitlines":
			return make_callable_type(reg,
				make_params(reg, {TYPE_BOOL}, {true}), make_list_type(reg, TYPE_STR))
		// Methods returning int
		case "find", "rfind", "index", "rindex":
			return make_callable_type(reg,
				make_params(reg, {TYPE_STR, TYPE_INT, TYPE_INT}, {false, true, true}), TYPE_INT)
		case "count":
			return make_callable_type(reg,
				make_params(reg, {TYPE_STR, TYPE_INT, TYPE_INT}, {false, true, true}), TYPE_INT)
		// 0-arg predicates returning bool
		case "startswith", "endswith":
			return make_callable_type(reg, make_params(reg, {TYPE_STR}), TYPE_BOOL)
		case "isdigit", "isalpha", "isalnum",
		     "isspace", "isupper", "islower", "istitle", "isnumeric",
		     "isidentifier", "isprintable", "isascii", "isdecimal":
			return make_callable_type(reg, no_params, TYPE_BOOL)
		}
	}

	// List methods
	if is_list_type(reg, receiver) {
		elem := get_list_element(reg, receiver)
		switch attr {
		case "append":
			return make_callable_type(reg, make_params(reg, {elem}), TYPE_NONE)
		case "extend":
			return make_callable_type(reg, make_params(reg, {TYPE_ANY}), TYPE_NONE)
		case "insert":
			return make_callable_type(reg, make_params(reg, {TYPE_INT, elem}), TYPE_NONE)
		case "remove":
			return make_callable_type(reg, make_params(reg, {elem}), TYPE_NONE)
		case "clear", "reverse":
			return make_callable_type(reg, no_params, TYPE_NONE)
		case "sort":
			return make_callable_type(reg,
				make_params(reg, {TYPE_ANY, TYPE_BOOL}, {true, true}), TYPE_NONE)
		case "pop":
			return make_callable_type(reg,
				make_params(reg, {TYPE_INT}, {true}), elem)
		case "index":
			return make_callable_type(reg,
				make_params(reg, {elem, TYPE_INT, TYPE_INT}, {false, true, true}), TYPE_INT)
		case "count":
			return make_callable_type(reg, make_params(reg, {elem}), TYPE_INT)
		case "copy":
			return make_callable_type(reg, no_params, receiver)
		}
	}

	// Dict methods
	if is_dict_type(reg, receiver) {
		t := get_type(reg, receiver)
		#partial switch info in t.info {
		case Dict_Type:
			switch attr {
			case "keys":
				return make_callable_type(reg, no_params, TYPE_ANY)
			case "values":
				return make_callable_type(reg, no_params, TYPE_ANY)
			case "items":
				return make_callable_type(reg, no_params, TYPE_ANY)
			case "get":
				// dict.get() returns V|None when no default provided
				get_ret := make_union_type(reg, {info.value, TYPE_NONE})
				return make_callable_type(reg,
					make_params(reg, {info.key, info.value}, {false, true}), get_ret)
			case "pop":
				return make_callable_type(reg,
					make_params(reg, {info.key, info.value}, {false, true}), info.value)
			case "setdefault":
				return make_callable_type(reg,
					make_params(reg, {info.key, info.value}, {false, true}), info.value)
			case "update":
				return make_callable_type(reg, make_params(reg, {TYPE_ANY}, {true}), TYPE_NONE)
			case "clear":
				return make_callable_type(reg, no_params, TYPE_NONE)
			case "copy":
				return make_callable_type(reg, no_params, receiver)
			}
		}
	}

	// Set methods
	if is_set_type(reg, receiver) {
		set_t := get_type(reg, receiver)
		#partial switch set_info in set_t.info {
		case Set_Type:
			switch attr {
			case "add":
				return make_callable_type(reg, make_params(reg, {set_info.element}), TYPE_NONE)
			case "remove", "discard":
				return make_callable_type(reg, make_params(reg, {set_info.element}), TYPE_NONE)
			case "pop":
				return make_callable_type(reg, no_params, set_info.element)
			case "clear":
				return make_callable_type(reg, no_params, TYPE_NONE)
			case "copy":
				return make_callable_type(reg, no_params, receiver)
			case "update", "intersection_update", "difference_update",
			     "symmetric_difference_update":
				return make_callable_type(reg, make_params(reg, {TYPE_ANY}), TYPE_NONE)
			case "union", "intersection", "difference", "symmetric_difference":
				return make_callable_type(reg, make_params(reg, {TYPE_ANY}), receiver)
			case "issubset", "issuperset", "isdisjoint":
				return make_callable_type(reg, make_params(reg, {TYPE_ANY}), TYPE_BOOL)
			}
		}
	}

	// Instance attribute lookup
	t := get_type(reg, receiver)
	#partial switch &info in t.info {
	case Instance_Type:
		cls := get_type(reg, info.class_type)
		#partial switch &cls_info in cls.info {
		case Class_Type:
			if attr_type, ok := cls_info.attrs[attr]; ok {
				return attr_type
			}
			// __getattr__ fallback: if class or any base defines __getattr__, any attribute is valid
			if _, has_getattr := cls_info.attrs["__getattr__"]; has_getattr {
				return TYPE_ANY
			}
			// Check base classes for __getattr__
			for base_id in cls_info.bases {
				base_t := get_type(reg, base_id)
				#partial switch &base_info in base_t.info {
				case Class_Type:
					if _, has_getattr := base_info.attrs["__getattr__"]; has_getattr {
						return TYPE_ANY
					}
				}
			}
			// Fallback: dict methods for classes inheriting from Mapping/MutableMapping/dict
			if _has_mapping_base(reg, &cls_info) {
				dict_result := _lookup_dict_method(attr, reg)
				if dict_result != TYPE_UNKNOWN { return dict_result }
			}
		}
	case Class_Type:
		if attr_type, ok := info.attrs[attr]; ok {
			// Enum members: Class.MEMBER returns Instance_Type(EnumClass), not the value type
			if info.is_enum && !_is_dunder(attr) {
				at := get_type(reg, attr_type)
				#partial switch _ in at.info {
				case Callable_Type:
					// Methods stay as-is
					return attr_type
				case:
					return make_instance_type(reg, receiver)
				}
			}
			return attr_type
		}
	case Module_Type:
		if attr_type, ok := info.exports[attr]; ok {
			return attr_type
		}
	case Protocol_Type:
		if attr_type, ok := info.methods[attr]; ok {
			return attr_type
		}
		if attr_type, ok := info.attrs[attr]; ok {
			return attr_type
		}
	case TypedDict_Type:
		if attr_type, ok := info.fields[attr]; ok {
			return attr_type
		}
		// TypedDict supports dict methods (get, pop, items, keys, values, etc.)
		dict_result := _lookup_dict_method(attr, reg)
		if dict_result != TYPE_UNKNOWN { return dict_result }
	case DataFrame_Type:
		return resolve_dataframe_attr(reg, &info, attr)
	case Series_Type:
		return resolve_series_attr(reg, &info, attr)
	case Tensor_Type:
		return resolve_tensor_attr(reg, &info, attr)
	}

	return TYPE_UNKNOWN
}

// ==================== Container Element Types ====================

get_subscript_type :: proc(container: Type_ID, reg: ^Type_Registry) -> Type_ID {
	t := get_type(reg, container)
	#partial switch info in t.info {
	case List_Type:  return info.element
	case Dict_Type:  return info.value
	case Tuple_Type:
		if len(info.elements) > 0 {
			return make_union_type(reg, info.elements)
		}
		return TYPE_UNKNOWN
	case Series_Type:
		return info.element
	case Tensor_Type:
		// Integer index on 1D → element type; otherwise sub-tensor
		if info.ndim <= 1 {
			return info.element_type
		}
		return make_tensor_type(reg, info.element_type, {}) // sub-tensor with unknown shape
	}
	if container == TYPE_STR { return TYPE_STR }
	if container == TYPE_BYTES { return TYPE_INT }
	return TYPE_UNKNOWN
}

// Bind comprehension loop variables so elt/key/value expressions can infer types
infer_comprehension_vars :: proc(generators: []parser.Comprehension, ctx: ^Infer_Context) {
	for gen in generators {
		iter_type := infer_expr(gen.iter, ctx)
		elem_type := get_iterator_element_type(iter_type, ctx.reg)
		assign_target(gen.target, elem_type, ctx)
	}
}

get_iterator_element_type :: proc(iter_type: Type_ID, reg: ^Type_Registry) -> Type_ID {
	t := get_type(reg, iter_type)
	#partial switch info in t.info {
	case List_Type:  return info.element
	case Set_Type:   return info.element
	case Dict_Type:  return info.key
	case Tuple_Type:
		if len(info.elements) > 0 {
			return make_union_type(reg, info.elements)
		}
		return TYPE_UNKNOWN
	}
	if iter_type == TYPE_STR { return TYPE_STR }
	if iter_type == TYPE_BYTES { return TYPE_INT }

	// User-defined iterables: check __iter__ → return type → __next__ → return type
	#partial switch inst in t.info {
	case Instance_Type:
		cls := get_type(reg, inst.class_type)
		if ci, ci_ok := cls.info.(Class_Type); ci_ok {
			if iter_method, has := ci.attrs["__iter__"]; has {
				iter_m := get_type(reg, iter_method)
				if iter_ct, ok := iter_m.info.(Callable_Type); ok {
					iter_ret := iter_ct.return_type
					if iter_ret != TYPE_UNKNOWN && iter_ret != TYPE_ANY {
						// Check if iterator has __next__
						rt := get_type(reg, iter_ret)
						#partial switch ri in rt.info {
						case Instance_Type:
							icls := get_type(reg, ri.class_type)
							if ici, ici_ok := icls.info.(Class_Type); ici_ok {
								if next_m, has_next := ici.attrs["__next__"]; has_next {
									next_t := get_type(reg, next_m)
									if nc, nc_ok := next_t.info.(Callable_Type); nc_ok {
										if nc.return_type != TYPE_UNKNOWN { return nc.return_type }
									}
								}
							}
						}
						// Fallback: use __iter__ return type directly if it resolves
						return iter_ret
					}
				}
			}
			// Old-style iteration: __getitem__(int) → element type
			if getitem_m, has := ci.attrs["__getitem__"]; has {
				gi_t := get_type(reg, getitem_m)
				if gi_ct, ok := gi_t.info.(Callable_Type); ok {
					if gi_ct.return_type != TYPE_UNKNOWN { return gi_ct.return_type }
				}
			}
		}
	}

	return TYPE_UNKNOWN
}

// ==================== Type Unification ====================

unify_types :: proc(types: []Type_ID, reg: ^Type_Registry) -> Type_ID {
	if len(types) == 0 { return TYPE_UNKNOWN }
	if len(types) == 1 { return types[0] }

	// If all same, return that type
	all_same := true
	for t in types[1:] {
		if t != types[0] { all_same = false; break }
	}
	if all_same { return types[0] }

	// Otherwise union
	return make_union_type(reg, types)
}

// ==================== Parameter Resolution ====================

resolve_params :: proc(args: ^parser.Arguments, ctx: ^Infer_Context) -> []Param_Type {
	total := len(args.posonlyargs) + len(args.args) + len(args.kwonlyargs)
	if args.vararg != nil { total += 1 }
	if args.kwarg != nil { total += 1 }

	params := make([]Param_Type, total, ctx.reg.allocator)
	idx := 0

	// Position-only args + regular args share the `defaults` list (filled from the end)
	n_defaults := len(args.defaults)
	n_positional := len(args.posonlyargs) + len(args.args)  // total positional params
	for a, i in args.posonlyargs {
		has_default := i >= (n_positional - n_defaults)
		params[idx] = Param_Type{
			name = a.arg,
			type_id = resolve_annotation(a.annotation, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env),
			has_default = has_default,
		}
		idx += 1
	}

	// Regular args
	n_args := len(args.args)
	for a, i in args.args {
		has_default := (len(args.posonlyargs) + i) >= (n_positional - n_defaults)
		params[idx] = Param_Type{
			name = a.arg,
			type_id = resolve_annotation(a.annotation, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env),
			has_default = has_default,
		}
		idx += 1
	}

	// *args — resolve annotation if present (e.g., *args: int means each arg is int)
	if args.vararg != nil {
		vararg_type := TYPE_ANY
		if args.vararg.annotation != nil {
			resolved := resolve_annotation(args.vararg.annotation, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
			if resolved != TYPE_UNKNOWN { vararg_type = resolved }
		}
		params[idx] = Param_Type{
			name = args.vararg.arg,
			type_id = vararg_type,
			has_default = true,
			is_variadic = true,
		}
		idx += 1
	}

	// Keyword-only args
	for a, i in args.kwonlyargs {
		has_default := i < len(args.kw_defaults) && args.kw_defaults[i] != nil
		params[idx] = Param_Type{
			name = a.arg,
			type_id = resolve_annotation(a.annotation, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env),
			has_default = has_default,
		}
		idx += 1
	}

	// **kwargs — resolve annotation if present (e.g., **kwargs: str means each value is str)
	if args.kwarg != nil {
		kwarg_type := TYPE_ANY
		if args.kwarg.annotation != nil {
			resolved := resolve_annotation(args.kwarg.annotation, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
			if resolved != TYPE_UNKNOWN { kwarg_type = resolved }
		}
		params[idx] = Param_Type{
			name = args.kwarg.arg,
			type_id = kwarg_type,
			has_default = true,
			is_variadic = true,
		}
		idx += 1
	}

	return params[:idx]
}

// ==================== Shape-Aware Tensor Inference ====================

// For mimir.array functions, compute a shaped Tensor_Type from the call arguments.
// Returns TYPE_UNKNOWN if this isn't a shape-relevant call or shape can't be determined.
infer_shaped_return :: proc(e: ^parser.Call_Expr, base_return: Type_ID, ctx: ^Infer_Context) -> Type_ID {
	// Only works for direct name calls
	name_expr, is_name := e.func.(^parser.Name_Expr)
	if !is_name { return TYPE_UNKNOWN }

	sym_id, ref_ok := binder.get_ref(ctx.bind_result, rawptr(name_expr))
	if !ref_ok { return TYPE_UNKNOWN }

	semantic, has := ctx.shape_reg.semantics[sym_id]
	if !has { return TYPE_UNKNOWN }

	// Get base tensor element type from the return type
	base_tensor := get_tensor_info(ctx.reg, base_return)
	if base_tensor == nil { return TYPE_UNKNOWN }
	elem_type := base_tensor.element_type

	switch semantic {
	case .Creation:
		// zeros(shape), ones(shape), array(data) — first arg is shape
		if len(e.args) == 0 { return TYPE_UNKNOWN }
		shape := extract_shape_from_arg(e.args[0], ctx.const_map, ctx.bind_result, ctx.reg.allocator)
		if len(shape) > 0 {
			return make_tensor_type(ctx.reg, elem_type, shape)
		}

	case .Arange:
		// arange(stop) or arange(start, stop) or arange(start, stop, step)
		shape := extract_arange_shape(e.args, ctx.reg.allocator)
		if len(shape) > 0 {
			return make_tensor_type(ctx.reg, elem_type, shape)
		}

	case .Matmul:
		// matmul(a, b) — compute result shape from operand shapes
		if len(e.args) < 2 { return TYPE_UNKNOWN }
		a_type := TYPE_UNKNOWN
		if t, ok := ctx.expr_types[expr_to_rawptr(e.args[0])]; ok { a_type = t }
		b_type := TYPE_UNKNOWN
		if t, ok := ctx.expr_types[expr_to_rawptr(e.args[1])]; ok { b_type = t }

		a_tensor := get_tensor_info(ctx.reg, a_type)
		b_tensor := get_tensor_info(ctx.reg, b_type)
		if a_tensor == nil || b_tensor == nil { return TYPE_UNKNOWN }
		if a_tensor.ndim == 0 || b_tensor.ndim == 0 { return TYPE_UNKNOWN }

		result_shape, ok, _ := validate_matmul(a_tensor.shape, b_tensor.shape, ctx.reg.allocator)
		if ok {
			return make_tensor_type(ctx.reg, elem_type, result_shape)
		}
		// If not ok, still return shape-erased — error emitted by shape pass
		return TYPE_UNKNOWN

	case .Reshape:
		// reshape(a, new_shape) — compute result shape
		if len(e.args) < 2 { return TYPE_UNKNOWN }
		new_shape := extract_shape_from_arg(e.args[1], ctx.const_map, ctx.bind_result, ctx.reg.allocator)
		if len(new_shape) > 0 {
			return make_tensor_type(ctx.reg, elem_type, new_shape)
		}

	case .Transpose:
		// transpose(a) — reverse shape
		if len(e.args) == 0 { return TYPE_UNKNOWN }
		a_type := TYPE_UNKNOWN
		if t, ok := ctx.expr_types[expr_to_rawptr(e.args[0])]; ok { a_type = t }
		a_tensor := get_tensor_info(ctx.reg, a_type)
		if a_tensor == nil || a_tensor.ndim == 0 { return TYPE_UNKNOWN }

		reversed := make([]int, a_tensor.ndim, ctx.reg.allocator)
		for i := 0; i < a_tensor.ndim; i += 1 {
			reversed[i] = a_tensor.shape[a_tensor.ndim - 1 - i]
		}
		return make_tensor_type(ctx.reg, elem_type, reversed)

	case .Reduction:
		// sum(a), mean(a) — scalar result (shape-erased)
		return TYPE_UNKNOWN // Falls through to base_return

	case .None:
		// No shape semantic
	}

	return TYPE_UNKNOWN
}

// ==================== Match/Case Type Checking ====================

// check_match_stmt: infer subject, map case blocks to patterns, check exhaustiveness.
check_match_stmt :: proc(s: ^parser.Match_Stmt, ctx: ^Infer_Context) {
	subject_type := infer_expr(s.subject, ctx)
	if ctx.cfg == nil || ctx.match_case_envs == nil { return }

	// Get current block's edges — case blocks are successors with Case_Match/Case_Default
	block := flow.get_block(ctx.cfg, ctx.current_block)
	if block == nil { return }

	case_idx := 0
	has_wildcard := false
	// MATCH002: track consumed class types for dead pattern detection
	consumed_class_types := make([dynamic]Type_ID, 0, 4, ctx.reg.allocator)

	for i in 0..<len(block.succs) {
		kind := block.edge_kinds[i]
		if kind != .Case_Match && kind != .Case_Default { continue }

		target_block := block.succs[i]
		if case_idx >= len(s.cases) { break }

		mc := s.cases[case_idx]
		case_idx += 1

		// MATCH002: case after wildcard is dead
		if has_wildcard && mc.guard == nil {
			pattern_loc := _match_pattern_loc(mc.pattern, s.loc)
			emit_diagnostic(ctx, pattern_loc, "MATCH002", .Warning,
				"Unreachable match case — wildcard case above matches everything",
				"A wildcard pattern (case _:) matches all values, making subsequent cases unreachable",
				"Move this case before the wildcard, or remove it")
		}

		// Build pattern bindings for this case block
		bindings := make(map[binder.Symbol_ID]Type_ID, 4, ctx.reg.allocator)
		pattern_type := bind_match_pattern(mc.pattern, subject_type, &bindings, ctx)

		// MATCH002: check if this value pattern is subsumed by an earlier class pattern
		if mc.guard == nil {
			if _, is_value := mc.pattern.(^parser.Match_Value); is_value {
				for consumed in consumed_class_types {
					if is_assignable(ctx.reg, pattern_type, consumed) {
						pattern_loc := _match_pattern_loc(mc.pattern, s.loc)
						emit_diagnostic(ctx, pattern_loc, "MATCH002", .Warning,
							"Unreachable match case — broader pattern above already matches",
							"A class pattern above matches all values of this type, making this case unreachable",
							"Move specific value cases before class/type patterns")
						break
					}
				}
			}
			// Track class patterns
			if _, is_class := mc.pattern.(^parser.Match_Class); is_class {
				if pattern_type != TYPE_UNKNOWN {
					append(&consumed_class_types, pattern_type)
				}
			}
		}

		// Check guard expression (with pattern bindings temporarily injected)
		if mc.guard != nil {
			for sym_id, type_id in bindings {
				ctx.env.types[sym_id] = type_id
			}
			infer_expr(mc.guard, ctx)
		}

		// Track exhaustiveness — wildcard without guard counts
		if kind == .Case_Default && mc.guard == nil {
			has_wildcard = true
		}

		ctx.match_case_envs[target_block] = Match_Case_Env{
			bindings = bindings,
		}
	}

	// MATCH001: Non-exhaustive match
	// Check if class patterns cover all union members before flagging
	is_exhaustive := has_wildcard
	if !is_exhaustive && len(consumed_class_types) > 0 {
		st := get_type(ctx.reg, subject_type)
		#partial switch union_info in st.info {
		case Union_Type:
			all_covered := true
			for member in union_info.members {
				covered := false
				for consumed in consumed_class_types {
					// Direct assignability check
					if is_assignable(ctx.reg, member, consumed) || is_assignable(ctx.reg, consumed, member) {
						covered = true
						break
					}
					// Builtin class pattern: Instance_Type wrapping a Callable that returns the primitive
					ct := get_type(ctx.reg, consumed)
					#partial switch inst in ct.info {
					case Instance_Type:
						inner := get_type(ctx.reg, inst.class_type)
						#partial switch callable in inner.info {
						case Callable_Type:
							if callable.return_type == member {
								covered = true
							}
						}
					}
					if covered { break }
				}
				if !covered { all_covered = false; break }
			}
			if all_covered { is_exhaustive = true }
		}
	}
	if !is_exhaustive && len(s.cases) > 0 {
		emit_diagnostic(ctx, s.loc, "MATCH001", .Warning,
			"Non-exhaustive match statement",
			"Match may not handle all possible values of the subject",
			"Add a wildcard case: case _: ...")
	}
}

// Get the source location of a match pattern for diagnostic reporting.
_match_pattern_loc :: proc(pattern: parser.Pattern, fallback: parser.Src_Loc) -> parser.Src_Loc {
	if pattern == nil { return fallback }
	#partial switch p in pattern {
	case ^parser.Match_Value:  return p.loc
	case ^parser.Match_Class:  return p.loc
	case ^parser.Match_As:     return p.loc
	case ^parser.Match_Or:     return p.loc
	case ^parser.Match_Star:   return p.loc
	case ^parser.Match_Sequence: return p.loc
	case ^parser.Match_Mapping:  return p.loc
	case ^parser.Match_Singleton: return p.loc
	}
	return fallback
}

// bind_match_pattern: recursively bind pattern variables into the env map.
// Returns the narrowed type of the subject for this pattern.
bind_match_pattern :: proc(
	pattern: parser.Pattern,
	subject_type: Type_ID,
	bindings: ^map[binder.Symbol_ID]Type_ID,
	ctx: ^Infer_Context,
) -> Type_ID {
	if pattern == nil { return subject_type }

	#partial switch p in pattern {
	case ^parser.Match_As:
		// case _ (wildcard): empty name
		// case pattern as name: bind name to narrowed type
		narrowed := subject_type
		if p.pattern != nil {
			narrowed = bind_match_pattern(p.pattern, subject_type, bindings, ctx)
		}
		if len(p.name) > 0 {
			if sym_id := _match_lookup_sym(p.name, ctx); sym_id != 0 {
				bindings[sym_id] = narrowed
			}
		}
		return narrowed

	case ^parser.Match_Value:
		// case 42, case "hello" — infer the value's type
		if p.value != nil {
			infer_expr(p.value, ctx)
		}
		return subject_type

	case ^parser.Match_Singleton:
		// case True/False/None
		#partial switch _ in p.value {
		case parser.Const_None:
			return TYPE_NONE
		case bool:
			return TYPE_BOOL
		}
		return subject_type

	case ^parser.Match_Class:
		// case ClassName(attr=val, ...) — narrow to class type
		class_type := TYPE_UNKNOWN
		if p.cls != nil {
			class_type = infer_expr(p.cls, ctx)
		}
		// Bind keyword pattern variables
		for i in 0..<len(p.kwd_patterns) {
			kwd_type := TYPE_ANY
			// Try to resolve attribute type from class
			if class_type != TYPE_UNKNOWN {
				ct := get_type(ctx.reg, class_type)
				if ct != nil {
					#partial switch class_info in ct.info {
					case Class_Type:
						if i < len(p.kwd_attrs) {
							if attr_type, has := class_info.attrs[p.kwd_attrs[i]]; has {
								kwd_type = attr_type
							}
						}
					}
				}
			}
			bind_match_pattern(p.kwd_patterns[i], kwd_type, bindings, ctx)
		}
		// Bind positional pattern variables
		for pat in p.patterns {
			bind_match_pattern(pat, TYPE_ANY, bindings, ctx)
		}
		// Narrow subject to the class instance type
		if class_type != TYPE_UNKNOWN && class_type != TYPE_ANY {
			// Builtin class patterns (int, str, float, bool): class_type is a Callable_Type
			// (constructor). Extract return_type for the narrowed type.
			ct := get_type(ctx.reg, class_type)
			if ct != nil {
				#partial switch callable in ct.info {
				case Callable_Type:
					if callable.return_type != TYPE_UNKNOWN {
						return callable.return_type
					}
				}
			}
			return make_instance_type(ctx.reg, class_type)
		}
		return subject_type

	case ^parser.Match_Sequence:
		// case [x, y, z] — bind elements
		elem_type := get_iterator_element_type(subject_type, ctx.reg)
		for pat in p.patterns {
			bind_match_pattern(pat, elem_type, bindings, ctx)
		}
		return subject_type

	case ^parser.Match_Mapping:
		// case {"key": val, **rest} — bind values and rest
		val_type := TYPE_ANY
		// Try to get dict value type from subject
		st := get_type(ctx.reg, subject_type)
		if st != nil {
			#partial switch dict_info in st.info {
			case Dict_Type:
				val_type = dict_info.value
			}
		}
		for i in 0..<len(p.patterns) {
			if i < len(p.keys) {
				infer_expr(p.keys[i], ctx)
			}
			bind_match_pattern(p.patterns[i], val_type, bindings, ctx)
		}
		if len(p.rest) > 0 {
			if sym_id := _match_lookup_sym(p.rest, ctx); sym_id != 0 {
				bindings[sym_id] = make_dict_type(ctx.reg, TYPE_STR, val_type)
			}
		}
		return subject_type

	case ^parser.Match_Star:
		// case [first, *rest] — rest is a list
		if len(p.name) > 0 {
			if sym_id := _match_lookup_sym(p.name, ctx); sym_id != 0 {
				elem_type := get_iterator_element_type(subject_type, ctx.reg)
				bindings[sym_id] = make_list_type(ctx.reg, elem_type)
			}
		}
		return subject_type

	case ^parser.Match_Or:
		// case 1 | 2 | 3 — bind from first alternative (all must bind same names per PEP 634)
		for pat in p.patterns {
			bind_match_pattern(pat, subject_type, bindings, ctx)
		}
		return subject_type
	}

	return subject_type
}

// Look up a symbol by name in the current scope (for match pattern variables).
// Check if a Type_ID resolves to an Any_Type (canonical or non-canonical from stubs)
_is_any_type :: proc(t: Type_ID, reg: ^Type_Registry) -> bool {
	if t == TYPE_ANY { return true }
	typ := get_type(reg, t)
	if typ == nil { return false }
	_, ok := typ.info.(Any_Type)
	return ok
}

// Check if a type is a union containing Unknown — indicates partial resolution
_union_has_unknown :: proc(t: Type_ID, reg: ^Type_Registry) -> bool {
	typ := get_type(reg, t)
	if typ == nil { return false }
	if ut, ok := typ.info.(Union_Type); ok {
		for m in ut.members {
			if m == TYPE_UNKNOWN { return true }
		}
	}
	return false
}

_match_lookup_sym :: proc(name: string, ctx: ^Infer_Context) -> binder.Symbol_ID {
	scope := binder.result_get_scope(ctx.bind_result, ctx.scope_id)
	if scope == nil { return 0 }
	if sym_id, found := scope.symbols[name]; found {
		return sym_id
	}
	return 0
}

// ==================== Helpers ====================

assign_expr_type :: proc(expr: parser.Expr, type_id: Type_ID, ctx: ^Infer_Context) {
	#partial switch e in expr {
	case ^parser.Name_Expr:
		if sym_id, ok := binder.get_ref(ctx.bind_result, rawptr(e)); ok {
			ctx.env.types[sym_id] = type_id
		}
	}
}

expr_to_rawptr :: proc(expr: parser.Expr) -> rawptr {
	switch e in expr {
	case ^parser.Bool_Op_Expr:    return rawptr(e)
	case ^parser.Named_Expr:     return rawptr(e)
	case ^parser.Bin_Op_Expr:    return rawptr(e)
	case ^parser.Unary_Op_Expr:  return rawptr(e)
	case ^parser.Lambda_Expr:    return rawptr(e)
	case ^parser.If_Expr:        return rawptr(e)
	case ^parser.Dict_Expr:      return rawptr(e)
	case ^parser.Set_Expr:       return rawptr(e)
	case ^parser.List_Comp:      return rawptr(e)
	case ^parser.Set_Comp:       return rawptr(e)
	case ^parser.Dict_Comp:      return rawptr(e)
	case ^parser.Generator_Expr: return rawptr(e)
	case ^parser.Await_Expr:     return rawptr(e)
	case ^parser.Yield_Expr:     return rawptr(e)
	case ^parser.Yield_From_Expr: return rawptr(e)
	case ^parser.Compare_Expr:   return rawptr(e)
	case ^parser.Call_Expr:      return rawptr(e)
	case ^parser.Formatted_Value: return rawptr(e)
	case ^parser.Joined_Str:     return rawptr(e)
	case ^parser.Constant_Expr:  return rawptr(e)
	case ^parser.Attribute_Expr: return rawptr(e)
	case ^parser.Subscript_Expr: return rawptr(e)
	case ^parser.Starred_Expr:   return rawptr(e)
	case ^parser.Name_Expr:      return rawptr(e)
	case ^parser.List_Expr:      return rawptr(e)
	case ^parser.Tuple_Expr:     return rawptr(e)
	case ^parser.Slice_Expr:     return rawptr(e)
	}
	return nil
}

// ==================== Typing Special Forms ====================

try_typing_call :: proc(e: ^parser.Call_Expr, ctx: ^Infer_Context) -> (Type_ID, bool) {
	// collections.namedtuple("Name", [...]) → intercept as NamedTuple
	if attr, attr_ok := e.func.(^parser.Attribute_Expr); attr_ok {
		if attr.attr == "namedtuple" {
			if mod, mod_ok := attr.value.(^parser.Name_Expr); mod_ok {
				if mod.id == "collections" {
					return handle_namedtuple_call(e, ctx), true
				}
			}
		}
		return TYPE_UNKNOWN, false
	}

	name_expr, ok := e.func.(^parser.Name_Expr)
	if !ok { return TYPE_UNKNOWN, false }

	// Check typing imports
	if orig_name, is_typing := ctx.bind_result.typing_names[name_expr.id]; is_typing {
		switch orig_name {
		case "assert_type": return handle_assert_type(e, ctx), true
		case "reveal_type": return handle_reveal_type(e, ctx), true
		case "cast":        return handle_cast(e, ctx), true
		case "TypeVar":
			return handle_typevar(e, ctx), true
		case "ParamSpec":
			// ParamSpec('P') — captures parameter signatures for decorators.
			// Minimal support: treat as TYPE_ANY (any parameter list).
			for arg in e.args { infer_expr(arg, ctx) }
			return TYPE_ANY, true
		case "TypeVarTuple":
			return handle_typevartuple(e, ctx), true
		case "TypedDict":
			return handle_typeddict_call(e, ctx), true
		case "NamedTuple":
			return handle_namedtuple_call(e, ctx), true
		case "NewType":
			return handle_newtype_call(e, ctx), true
		case:
			// Unknown typing form — infer args, don't error
			for arg in e.args { infer_expr(arg, ctx) }
			return TYPE_UNKNOWN, true
		}
	}

	// reveal_type is also a Python 3.11+ builtin (no import needed)
	if name_expr.id == "reveal_type" {
		return handle_reveal_type(e, ctx), true
	}

	return TYPE_UNKNOWN, false
}

handle_assert_type :: proc(e: ^parser.Call_Expr, ctx: ^Infer_Context) -> Type_ID {
	if len(e.args) != 2 {
		emit_diagnostic(ctx, e.loc, "T006", .Error,
			len(e.args) < 2 ? "Too few arguments" : "Too many arguments",
			fmt.aprintf("assert_type requires exactly 2 arguments, got %d", len(e.args),
				allocator = ctx.reg.allocator),
			"Usage: assert_type(value, expected_type)")
		for arg in e.args { infer_expr(arg, ctx) }
		return TYPE_UNKNOWN
	}

	val_type := infer_expr(e.args[0], ctx)
	expected := resolve_annotation(e.args[1], ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)

	if expected != TYPE_UNKNOWN && expected != TYPE_ANY &&
	   val_type != TYPE_UNKNOWN && val_type != TYPE_ANY {
		if !is_assignable(ctx.reg, val_type, expected) ||
		   !is_assignable(ctx.reg, expected, val_type) {
			emit_diagnostic(ctx, e.loc, "T006", .Error,
				"assert_type failed",
				fmt.aprintf("Expression has type '%s', asserted type is '%s'",
					type_to_string(ctx.reg, val_type),
					type_to_string(ctx.reg, expected),
					allocator = ctx.reg.allocator),
				"Fix the type annotation or the expression")
		}
	}

	return val_type
}

handle_reveal_type :: proc(e: ^parser.Call_Expr, ctx: ^Infer_Context) -> Type_ID {
	if len(e.args) != 1 {
		emit_diagnostic(ctx, e.loc, "T009", .Error,
			len(e.args) < 1 ? "Too few arguments" : "Too many arguments",
			fmt.aprintf("reveal_type requires exactly 1 argument, got %d", len(e.args),
				allocator = ctx.reg.allocator),
			"Usage: reveal_type(expression)")
		for arg in e.args { infer_expr(arg, ctx) }
		return TYPE_UNKNOWN
	}

	val_type := infer_expr(e.args[0], ctx)
	emit_diagnostic(ctx, e.loc, "T009", .Info,
		"Revealed type",
		fmt.aprintf("Type of expression is '%s'",
			type_to_string(ctx.reg, val_type),
			allocator = ctx.reg.allocator),
		"")

	return val_type
}

handle_cast :: proc(e: ^parser.Call_Expr, ctx: ^Infer_Context) -> Type_ID {
	if len(e.args) != 2 {
		for arg in e.args { infer_expr(arg, ctx) }
		return TYPE_UNKNOWN
	}

	target_type := resolve_annotation(e.args[0], ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
	infer_expr(e.args[1], ctx) // type-check the value
	return target_type
}

import "core:fmt"

emit_diagnostic :: proc(ctx: ^Infer_Context, loc: parser.Src_Loc, code: string, severity: core.Severity,
	what: string, why: string, fix: string) {
	// Suppress diagnostics on lines with # type: ignore
	if ctx.type_ignore_lines != nil {
		if loc.line in ctx.type_ignore_lines^ { return }
	}
	append(ctx.diagnostics, core.Diagnostic{
		severity = severity,
		location = core.Location{
			file   = ctx.file_path,
			line   = int(loc.line),
			column = int(loc.col),
		},
		code = code,
		what = what,
		why  = why,
		fix  = fix,
	})
}

// ==================== Overload Resolution ====================

resolve_overload :: proc(e: ^parser.Call_Expr, sigs: []Type_ID, ctx: ^Infer_Context) -> Type_ID {
	// Infer arg types
	arg_types := make([]Type_ID, len(e.args), ctx.reg.allocator)
	for arg, i in e.args {
		arg_types[i] = infer_expr(arg, ctx)
	}
	for kw in e.keywords {
		infer_expr(kw.value, ctx)
	}
	// Try each overload signature — first match wins
	for sig_id in sigs {
		sig := get_type(ctx.reg, sig_id)
		#partial switch info in sig.info {
		case Callable_Type:
			if overload_sig_matches(arg_types, e.keywords, info.params, ctx.reg) {
				return info.return_type
			}
		}
	}
	// No overload matched — try the implementation signature (non-@overload function)
	// The implementation signature is stored in the env as the function type
	#partial switch fn in e.func {
	case ^parser.Name_Expr:
		if sym_id, ok := binder.get_ref(ctx.bind_result, rawptr(fn)); ok {
			if impl_type, impl_ok := ctx.env.types[sym_id]; impl_ok {
				impl_t := get_type(ctx.reg, impl_type)
				#partial switch impl_info in impl_t.info {
				case Callable_Type:
					// Implementation sig is the non-@overload version — use its return type
					return impl_info.return_type
				}
			}
		}
	}
	return TYPE_UNKNOWN
}

overload_sig_matches :: proc(arg_types: []Type_ID, keywords: []parser.Keyword, params: []Param_Type, reg: ^Type_Registry) -> bool {
	total := len(arg_types) + len(keywords)
	required := 0
	has_variadic := false
	for p in params {
		if p.is_variadic { has_variadic = true; continue }
		if !p.has_default { required += 1 }
	}
	if total < required { return false }
	if !has_variadic && total > len(params) { return false }
	// Check positional args
	for arg_type, i in arg_types {
		if i >= len(params) {
			if has_variadic { continue }
			return false
		}
		if arg_type != TYPE_UNKNOWN && arg_type != TYPE_ANY &&
		   params[i].type_id != TYPE_UNKNOWN && params[i].type_id != TYPE_ANY {
			if !is_assignable(reg, arg_type, params[i].type_id) {
				return false
			}
		}
	}
	// Check keyword args
	for kw in keywords {
		if kw.arg == "" { continue } // **kwargs unpacking
		found := false
		for p in params {
			if p.name == kw.arg {
				found = true
				break
			}
		}
		if !found && !has_variadic { return false }
	}
	return true
}

fmt_binop_error :: proc(op: parser.Binary_Op, left: Type_ID, right: Type_ID, reg: ^Type_Registry) -> string {
	return fmt.aprintf("Cannot apply operator to '%s' and '%s'",
		type_to_string(reg, left), type_to_string(reg, right),
		allocator = reg.allocator)
}

fmt_type_mismatch :: proc(actual: Type_ID, expected: Type_ID, reg: ^Type_Registry) -> string {
	return fmt.aprintf("Expression has type '%s', expected '%s'",
		type_to_string(reg, actual), type_to_string(reg, expected),
		allocator = reg.allocator)
}

fmt_arg_count_error :: proc(expected: int, actual: int, reg: ^Type_Registry) -> string {
	return fmt.aprintf("Expected %d argument(s), got %d", expected, actual,
		allocator = reg.allocator)
}

// ==================== TypeVar Handling ====================

handle_typevar :: proc(e: ^parser.Call_Expr, ctx: ^Infer_Context) -> Type_ID {
	name := ""
	bound := TYPE_UNKNOWN
	constraints := make([dynamic]Type_ID, 0, 4, ctx.reg.allocator)

	// First arg is the name (string constant)
	if len(e.args) >= 1 {
		#partial switch arg in e.args[0] {
		case ^parser.Constant_Expr:
			if s, ok := arg.value.(string); ok {
				name = s
			}
		}
	}

	// Remaining positional args are constraints
	for i := 1; i < len(e.args); i += 1 {
		ct := resolve_annotation(e.args[i], ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
		append(&constraints, ct)
	}

	// Check keywords for bound=
	for kw in e.keywords {
		if kw.arg == "bound" {
			bound = resolve_annotation(kw.value, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
		}
	}

	constraint_slice: []Type_ID
	if len(constraints) > 0 {
		constraint_slice = make([]Type_ID, len(constraints), ctx.reg.allocator)
		copy(constraint_slice, constraints[:])
	}

	return register_type(ctx.reg, TypeVar_Type{
		name        = name,
		bound       = bound,
		constraints = constraint_slice,
	})
}

// ==================== TypeVarTuple Handling (PEP 646) ====================

handle_typevartuple :: proc(e: ^parser.Call_Expr, ctx: ^Infer_Context) -> Type_ID {
	name := ""
	// First arg is the name (string constant)
	if len(e.args) >= 1 {
		#partial switch arg in e.args[0] {
		case ^parser.Constant_Expr:
			if s, ok := arg.value.(string); ok {
				name = s
			}
		}
	}

	return register_type(ctx.reg, TypeVarTuple_Type{
		name = name,
	})
}

// ==================== TypedDict Functional Syntax ====================

handle_typeddict_call :: proc(e: ^parser.Call_Expr, ctx: ^Infer_Context) -> Type_ID {
	name := ""
	// First arg: name string
	if len(e.args) >= 1 {
		#partial switch arg in e.args[0] {
		case ^parser.Constant_Expr:
			if s, ok := arg.value.(string); ok {
				name = s
			}
		}
	}

	fields := make(map[string]Type_ID, 8, ctx.reg.allocator)
	required_fields := make(map[string]bool, 4, ctx.reg.allocator)
	total := true

	// Second arg: dict of field_name: type
	if len(e.args) >= 2 {
		#partial switch arg in e.args[1] {
		case ^parser.Dict_Expr:
			for i in 0..<len(arg.keys) {
				key_name := ""
				#partial switch k in arg.keys[i] {
				case ^parser.Constant_Expr:
					if s, ok := k.value.(string); ok {
						key_name = s
					}
				}
				if len(key_name) > 0 {
					// Detect Required[T] / NotRequired[T] wrappers
					ann := arg.values[i]
					if sub, sub_ok := ann.(^parser.Subscript_Expr); sub_ok {
						wrapper_name := get_annotation_name(sub.value)
						if wrapper_name == "NotRequired" {
							required_fields[key_name] = false
							ann = sub.slice
						} else if wrapper_name == "Required" {
							required_fields[key_name] = true
							ann = sub.slice
						}
						// Also check typing_names alias
						if orig, ok := ctx.bind_result.typing_names[wrapper_name]; ok {
							if orig == "NotRequired" {
								required_fields[key_name] = false
								ann = sub.slice
							} else if orig == "Required" {
								required_fields[key_name] = true
								ann = sub.slice
							}
						}
					}
					field_type := resolve_annotation(ann, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
					fields[key_name] = field_type
				}
			}
		}
	}

	// Check keywords for total=False
	for kw in e.keywords {
		if kw.arg == "total" {
			#partial switch v in kw.value {
			case ^parser.Constant_Expr:
				if b, ok := v.value.(bool); ok {
					total = b
				}
			}
		}
	}

	return register_type(ctx.reg, TypedDict_Type{name = name, fields = fields, total = total, required_fields = required_fields})
}

// ==================== NamedTuple Functional Syntax ====================

handle_namedtuple_call :: proc(e: ^parser.Call_Expr, ctx: ^Infer_Context) -> Type_ID {
	name := ""
	// First arg: name string
	if len(e.args) >= 1 {
		#partial switch arg in e.args[0] {
		case ^parser.Constant_Expr:
			if s, ok := arg.value.(string); ok {
				name = s
			}
		}
	}

	attrs := make(map[string]Type_ID, 8, ctx.reg.allocator)
	params := make([dynamic]Param_Type, 0, 8, ctx.reg.allocator)

	// Keyword args: NamedTuple('Point', x=int, y=int)
	for &kw in e.keywords {
		if kw.arg == "" { continue }
		field_type := resolve_annotation(kw.value, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
		attrs[kw.arg] = field_type
		append(&params, Param_Type{name = kw.arg, type_id = field_type})
	}

	// Second arg list form: NamedTuple('Point', [('x', int), ('y', int)])
	if len(e.args) >= 2 && len(attrs) == 0 {
		#partial switch arg in e.args[1] {
		case ^parser.List_Expr:
			for elt in arg.elts {
				#partial switch tup in elt {
				case ^parser.Tuple_Expr:
					if len(tup.elts) >= 2 {
						field_name := ""
						#partial switch n in tup.elts[0] {
						case ^parser.Constant_Expr:
							if s, ok := n.value.(string); ok {
								field_name = s
							}
						}
						if len(field_name) > 0 {
							field_type := resolve_annotation(tup.elts[1], ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
							attrs[field_name] = field_type
							append(&params, Param_Type{name = field_name, type_id = field_type})
						}
					}
				// collections.namedtuple("Name", ["field1", "field2"]) — list of strings
				case ^parser.Constant_Expr:
					if field_name, ok := tup.value.(string); ok {
						attrs[field_name] = TYPE_ANY
						append(&params, Param_Type{name = field_name, type_id = TYPE_ANY})
					}
				}
			}
		}
	}

	// Build __init__ method
	init_type := make_callable_type(ctx.reg, params[:], TYPE_NONE)
	attrs["__init__"] = init_type

	// Register as Class_Type
	scope_id := binder.INVALID_SCOPE
	class_type_id := register_type(ctx.reg, Class_Type{
		name      = name,
		symbol_id = binder.INVALID_SYMBOL,
		scope_id  = scope_id,
		attrs     = attrs,
	})

	return class_type_id
}

// ==================== NewType (typing.NewType) ====================
//
// NewType('UserId', int) → creates a nominal type that's a distinct subtype of int.
// UserId(42) is the constructor. UserId is assignable TO int (subtype),
// but int is NOT assignable to UserId (requires explicit constructor).

handle_newtype_call :: proc(e: ^parser.Call_Expr, ctx: ^Infer_Context) -> Type_ID {
	name := ""
	base_type := TYPE_UNKNOWN

	// First arg: name string
	if len(e.args) >= 1 {
		#partial switch arg in e.args[0] {
		case ^parser.Constant_Expr:
			if s, ok := arg.value.(string); ok {
				name = s
			}
		}
	}

	// Second arg: base type
	if len(e.args) >= 2 {
		base_type = resolve_annotation(e.args[1], ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
	}

	if len(name) == 0 || base_type == TYPE_UNKNOWN {
		return TYPE_UNKNOWN
	}

	// Create a Class_Type that inherits from the base type.
	// This gives us nominal subtyping: NewType IS-A base, but base IS-NOT-A NewType.
	bases := make([]Type_ID, 1, ctx.reg.allocator)

	// Wrap primitive base types in a Class_Type for inheritance to work
	base_class := base_type
	bt := get_type(ctx.reg, base_type)
	#partial switch _ in bt.info {
	case Primitive_Type:
		// Primitives aren't Class_Types — create a synthetic class for the base
		// so is_class_subtype can traverse the chain.
		// Actually, just store the base — is_assignable handles primitive→primitive directly.
		// The NewType instance will use a special check in is_assignable.
		base_class = base_type
	case Instance_Type:
		base_class = bt.info.(Instance_Type).class_type
	}
	bases[0] = base_class

	// Constructor: takes base_type, returns NewType instance
	ctor_params := make([]Param_Type, 1, ctx.reg.allocator)
	ctor_params[0] = Param_Type{name = "val", type_id = base_type}

	attrs := make(map[string]Type_ID, 2, ctx.reg.allocator)

	class_type_id := register_type(ctx.reg, Class_Type{
		name      = name,
		symbol_id = binder.INVALID_SYMBOL,
		scope_id  = binder.INVALID_SCOPE,
		bases     = bases,
		attrs     = attrs,
	})

	instance_type := make_instance_type(ctx.reg, class_type_id)

	// The result of NewType() is a callable: (base_type) -> NewType_instance
	return make_callable_type(ctx.reg, ctor_params, instance_type)
}

// ==================== Generic Call Inference ====================

infer_generic_call :: proc(e: ^parser.Call_Expr, info: ^Callable_Type, ctx: ^Infer_Context) -> Type_ID {
	subs := make(map[Type_ID]Type_ID, 4, ctx.reg.allocator)

	n_args := len(e.args)
	n_total := n_args + len(e.keywords)
	n_params := len(info.params)

	// Check arg count (positional + keyword)
	required := 0
	for p in info.params {
		if !p.has_default { required += 1 }
	}
	if n_total < required {
		emit_diagnostic(ctx, e.loc, "T004", .Error,
			"Too few arguments",
			fmt_arg_count_error(required, n_total, ctx.reg),
			"Add missing arguments")
	} else if n_total > n_params {
		emit_diagnostic(ctx, e.loc, "T004", .Error,
			"Too many arguments",
			fmt_arg_count_error(n_params, n_total, ctx.reg),
			"Remove extra arguments")
	}

	// Match args against params, building substitution map
	for i := 0; i < min(n_args, n_params); i += 1 {
		arg_type := infer_expr(e.args[i], ctx, info.params[i].type_id)
		if contains_typevar(ctx.reg, info.params[i].type_id) {
			if !match_type(ctx.reg, info.params[i].type_id, arg_type, &subs) {
				emit_diagnostic(ctx, e.loc, "T002", .Error,
					"Incompatible argument type",
					fmt_type_mismatch(arg_type, info.params[i].type_id, ctx.reg),
					"Use the correct type")
			}
		} else {
			if info.params[i].type_id != TYPE_ANY && info.params[i].type_id != TYPE_UNKNOWN &&
			   arg_type != TYPE_UNKNOWN && arg_type != TYPE_ANY {
				if !is_assignable(ctx.reg, arg_type, info.params[i].type_id) {
					emit_diagnostic(ctx, e.loc, "T002", .Error,
						"Incompatible argument type",
						fmt_type_mismatch(arg_type, info.params[i].type_id, ctx.reg),
						"Use the correct type")
				}
			}
		}
	}

	// Match keyword args against params for TypeVar inference
	for kw in e.keywords {
		for &p in info.params {
			if p.name == kw.arg {
				kw_type := infer_expr(kw.value, ctx, p.type_id)
				if contains_typevar(ctx.reg, p.type_id) {
					if !match_type(ctx.reg, p.type_id, kw_type, &subs) {
						// TypeVar already bound to incompatible type
						emit_diagnostic(ctx, e.loc, "T002", .Error,
							"Incompatible keyword argument type",
							fmt_type_mismatch(kw_type, p.type_id, ctx.reg),
							"Use the correct type")
					}
				} else {
					if p.type_id != TYPE_ANY && p.type_id != TYPE_UNKNOWN &&
					   kw_type != TYPE_UNKNOWN && kw_type != TYPE_ANY {
						if !is_assignable(ctx.reg, kw_type, p.type_id) {
							emit_diagnostic(ctx, e.loc, "T002", .Error,
								"Incompatible keyword argument type",
								fmt_type_mismatch(kw_type, p.type_id, ctx.reg),
								"Use the correct type")
						}
					}
				}
				break
			}
		}
	}

	// Infer remaining args
	for i := n_params; i < n_args; i += 1 {
		infer_expr(e.args[i], ctx)
	}

	// Validate TypeVar bindings against bounds/constraints
	validate_typevar_bindings(ctx, &subs, e.loc)

	// Substitute return type
	return substitute_type(ctx.reg, info.return_type, subs)
}

infer_generic_constructor :: proc(e: ^parser.Call_Expr, info: ^Class_Type, class_type_id: Type_ID, ctx: ^Infer_Context, expected: Type_ID = TYPE_UNKNOWN) -> Type_ID {
	init_type_id, has_init := info.attrs["__init__"]
	if !has_init {
		for arg in e.args { infer_expr(arg, ctx) }
		return make_instance_type(ctx.reg, class_type_id)
	}

	init_t := get_type(ctx.reg, init_type_id)
	init_info, ok := &init_t.info.(Callable_Type)
	if !ok {
		for arg in e.args { infer_expr(arg, ctx) }
		return make_instance_type(ctx.reg, class_type_id)
	}

	// Use generic call logic: match args → build subs → specialize
	subs := make(map[Type_ID]Type_ID, 4, ctx.reg.allocator)

	n_args := len(e.args)
	n_total := n_args + len(e.keywords)
	n_params := len(init_info.params)

	required := 0
	for p in init_info.params {
		if !p.has_default { required += 1 }
	}
	if n_total < required {
		emit_diagnostic(ctx, e.loc, "T004", .Error,
			"Too few arguments",
			fmt_arg_count_error(required, n_total, ctx.reg),
			"Add missing arguments")
	} else if n_total > n_params {
		emit_diagnostic(ctx, e.loc, "T004", .Error,
			"Too many arguments",
			fmt_arg_count_error(n_params, n_total, ctx.reg),
			"Remove extra arguments")
	}

	for i := 0; i < min(n_args, n_params); i += 1 {
		arg_type := infer_expr(e.args[i], ctx, init_info.params[i].type_id)
		if contains_typevar(ctx.reg, init_info.params[i].type_id) {
			match_type(ctx.reg, init_info.params[i].type_id, arg_type, &subs)
		}
	}
	// Match keyword args against __init__ params for TypeVar inference
	for kw in e.keywords {
		for &p in init_info.params {
			if p.name == kw.arg {
				kw_type := infer_expr(kw.value, ctx, p.type_id)
				if contains_typevar(ctx.reg, p.type_id) {
					match_type(ctx.reg, p.type_id, kw_type, &subs)
				}
				break
			}
		}
	}
	for i := n_params; i < n_args; i += 1 {
		infer_expr(e.args[i], ctx)
	}

	validate_typevar_bindings(ctx, &subs, e.loc)

	// Build type_args from type_params using subs, falling back to expected annotation
	type_args := make([]Type_ID, len(info.type_params), ctx.reg.allocator)

	// Check if all type_params resolved via args
	all_resolved := true
	for tp in info.type_params {
		if _, found := subs[tp]; !found {
			all_resolved = false
			break
		}
	}

	// If unresolved and expected is a specialized instance of the same class, use it directly
	if !all_resolved && expected != TYPE_UNKNOWN {
		et := get_type(ctx.reg, expected)
		#partial switch ei in et.info {
		case Instance_Type:
			ct := get_type(ctx.reg, ei.class_type)
			#partial switch ci in ct.info {
			case Class_Type:
				if ci.symbol_id == info.symbol_id {
					return expected
				}
			}
		}
	}

	for tp, i in info.type_params {
		if concrete, found := subs[tp]; found {
			type_args[i] = concrete
		} else {
			type_args[i] = TYPE_ANY
		}
	}

	return specialize_class(ctx.reg, class_type_id, type_args)
}

validate_typevar_bindings :: proc(ctx: ^Infer_Context, subs: ^map[Type_ID]Type_ID, loc: parser.Src_Loc) {
	for tv_id, concrete in subs {
		tv := get_type(ctx.reg, tv_id)
		#partial switch tv_info in tv.info {
		case TypeVar_Type:
			// Check bound
			if tv_info.bound != TYPE_UNKNOWN && tv_info.bound != TYPE_ANY {
				if !is_assignable(ctx.reg, concrete, tv_info.bound) {
					emit_diagnostic(ctx, loc, "T008", .Error,
						"TypeVar bound violated",
						fmt.aprintf("Type '%s' is not assignable to bound '%s' of TypeVar '%s'",
							type_to_string(ctx.reg, concrete),
							type_to_string(ctx.reg, tv_info.bound),
							tv_info.name,
							allocator = ctx.reg.allocator),
						"Use a type compatible with the TypeVar bound")
				}
			}
			// Check constraints
			if len(tv_info.constraints) > 0 {
				matches := false
				for c in tv_info.constraints {
					if is_assignable(ctx.reg, concrete, c) {
						matches = true
						break
					}
				}
				if !matches {
					emit_diagnostic(ctx, loc, "T008", .Error,
						"TypeVar constraint violated",
						fmt.aprintf("Type '%s' doesn't match any constraint of TypeVar '%s'",
							type_to_string(ctx.reg, concrete),
							tv_info.name,
							allocator = ctx.reg.allocator),
						"Use a type matching one of the TypeVar constraints")
				}
			}
		}
	}
}
