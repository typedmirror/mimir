package checker

import "core:mem"

import parser "mimir:parser"
import binder "mimir:binder"
import flow   "mimir:flow"
import core   "mimir:core"

// ==================== Expression Type Inference ====================

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
		return infer_constant(e)

	case ^parser.Name_Expr:
		return infer_name(e, ctx)

	case ^parser.Bin_Op_Expr:
		left := infer_expr(e.left, ctx)
		right := infer_expr(e.right, ctx)
		result := infer_binop(e.op, left, right, ctx.reg)
		if result == TYPE_UNKNOWN && left != TYPE_UNKNOWN && right != TYPE_UNKNOWN {
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
		if result == TYPE_UNKNOWN && operand != TYPE_UNKNOWN && operand != TYPE_ANY {
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
		return make_union_type(ctx.reg, types[:])

	case ^parser.Call_Expr:
		return infer_call(e, ctx, expected)

	case ^parser.Attribute_Expr:
		receiver := infer_expr(e.value, ctx)
		result := lookup_attribute(receiver, e.attr, ctx.reg)
		// T007: flag undefined attributes on user-defined types
		if result == TYPE_UNKNOWN && receiver != TYPE_UNKNOWN && receiver != TYPE_ANY {
			rt := get_type(ctx.reg, receiver)
			should_flag := false
			#partial switch _ in rt.info {
			case Instance_Type, Class_Type, Module_Type, Protocol_Type, TypedDict_Type,
		     DataFrame_Type, Series_Type:
				should_flag = true
			}
			// Skip dunder attrs — implicit object methods not tracked yet
			if should_flag && !(len(e.attr) > 4 && e.attr[:2] == "__" && e.attr[len(e.attr)-2:] == "__") {
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
					emit_diagnostic(ctx, e.loc, "T001", .Error,
						"Invalid TypedDict key",
						fmt.aprintf("TypedDict '%s' has no key '%s'", td.name, key_str,
							allocator = ctx.reg.allocator),
						"Use a valid key")
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
		if e.value != nil {
			return infer_expr(e.value, ctx)
		}
		return TYPE_NONE

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

infer_constant :: proc(e: ^parser.Constant_Expr) -> Type_ID {
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

// ==================== Name Inference ====================

infer_name :: proc(e: ^parser.Name_Expr, ctx: ^Infer_Context) -> Type_ID {
	// Look up in binder refs
	if sym_id, ok := binder.get_ref(ctx.bind_result, rawptr(e)); ok {
		// Check environment first (flow-sensitive)
		if t, found := ctx.env.types[sym_id]; found {
			return t
		}
		// Fallback: check class_types registry (module-level classes visible in all scopes)
		if class_type, found := ctx.reg.class_types[sym_id]; found {
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

	// Helper: int or bool (Python promotes bool to int in arithmetic)
	left_intlike := left == TYPE_INT || left == TYPE_BOOL
	right_intlike := right == TYPE_INT || right == TYPE_BOOL

	switch op {
	case .Add:
		if left_intlike && right_intlike { return TYPE_INT }
		if is_numeric(reg, left) && is_numeric(reg, right) { return TYPE_FLOAT }
		if left == TYPE_STR && right == TYPE_STR { return TYPE_STR }
		if is_list_type(reg, left) && is_list_type(reg, right) { return left }

	case .Sub, .Mult:
		if left_intlike && right_intlike { return TYPE_INT }
		if is_numeric(reg, left) && is_numeric(reg, right) { return TYPE_FLOAT }
		// str * int or int * str
		if op == .Mult {
			if left == TYPE_STR && right_intlike { return TYPE_STR }
			if left_intlike && right == TYPE_STR { return TYPE_STR }
			// list * int or int * list
			if is_list_type(reg, left) && right_intlike { return left }
			if left_intlike && is_list_type(reg, right) { return right }
		}

	case .Div:
		if is_numeric(reg, left) && is_numeric(reg, right) { return TYPE_FLOAT }

	case .Floor_Div, .Mod:
		if left_intlike && right_intlike { return TYPE_INT }
		if is_numeric(reg, left) && is_numeric(reg, right) { return TYPE_FLOAT }

	case .Pow:
		if left_intlike && right_intlike { return TYPE_INT }
		if is_numeric(reg, left) && is_numeric(reg, right) { return TYPE_FLOAT }

	case .LShift, .RShift, .Bit_And, .Bit_Xor:
		if left_intlike && right_intlike { return TYPE_INT }

	case .Bit_Or:
		if left_intlike && right_intlike { return TYPE_INT }
		if is_set_type(reg, left) && is_set_type(reg, right) { return left }

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

	return TYPE_UNKNOWN // signals unsupported
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

	// super() or super(Cls, self) → Instance of first base class in current class context
	if name_expr, ok := e.func.(^parser.Name_Expr); ok && name_expr.id == "super" && (len(e.args) == 0 || len(e.args) == 2) && len(e.keywords) == 0 {
		if ctx.current_class != INVALID_TYPE {
			cls := get_type(ctx.reg, ctx.current_class)
			#partial switch cls_info in cls.info {
			case Class_Type:
				if len(cls_info.bases) > 0 {
					return make_instance_type(ctx.reg, cls_info.bases[0])
				}
			}
		}
		return TYPE_OBJECT
	}

	func_type := infer_expr(e.func, ctx)

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
			}
		}
		// Check for missing required fields (total=True by default)
		if info.total {
			provided := make(map[string]bool, len(e.keywords), ctx.reg.allocator)
			for kw in e.keywords {
				provided[kw.arg] = true
			}
			for field_name in info.fields {
				if !(field_name in provided) {
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
		// Generic class — infer TypeVar bindings from __init__ args
		if len(info.type_params) > 0 {
			return infer_generic_constructor(e, &info, func_type, ctx, expected)
		}
		// Calling a class = constructor → check __init__ args
		if init_type_id, ok := info.attrs["__init__"]; ok {
			init_t := get_type(ctx.reg, init_type_id)
			#partial switch &init_info in init_t.info {
			case Callable_Type:
				check_call_args(e, &init_info, ctx)
			case:
				for arg in e.args { infer_expr(arg, ctx) }
			}
		} else {
			// No __init__ — just infer args
			for arg in e.args { infer_expr(arg, ctx) }
		}
		return make_instance_type(ctx.reg, func_type)
	}

	// Unknown callable
	for arg in e.args {
		infer_expr(arg, ctx)
	}
	return TYPE_UNKNOWN
}

check_call_args :: proc(e: ^parser.Call_Expr, func_info: ^Callable_Type, ctx: ^Infer_Context) {
	// Count required params (no default)
	required := 0
	for p in func_info.params {
		if !p.has_default { required += 1 }
	}

	// Check arg count (positional + keyword)
	n_args := len(e.args)
	n_total := n_args + len(e.keywords)
	n_params := len(func_info.params)

	if n_total < required {
		emit_diagnostic(ctx, e.loc, "T004", .Error,
			"Too few arguments",
			fmt_arg_count_error(required, n_total, ctx.reg),
			"Add missing arguments")
	} else if n_total > n_params {
		if n_params == 0 {
			emit_diagnostic(ctx, e.loc, "T004", .Error,
				"Too many arguments",
				fmt_arg_count_error(n_params, n_total, ctx.reg),
				"Remove extra arguments")
		} else {
			// Check if last param is *args (explicit flag) or builtin with Any type (implicit)
			last := func_info.params[n_params - 1]
			if !last.is_variadic && last.type_id != TYPE_ANY {
				emit_diagnostic(ctx, e.loc, "T004", .Error,
					"Too many arguments",
					fmt_arg_count_error(n_params, n_total, ctx.reg),
					"Remove extra arguments")
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
	for i := 0; i < min(n_args, n_params); i += 1 {
		param_type := func_info.params[i].type_id
		arg_type := infer_expr(e.args[i], ctx, param_type)
		if param_type != TYPE_ANY && param_type != TYPE_UNKNOWN &&
		   arg_type != TYPE_UNKNOWN && arg_type != TYPE_ANY {
			if !is_assignable(ctx.reg, arg_type, param_type) {
				emit_diagnostic(ctx, e.loc, "T002", .Error,
					"Incompatible argument type",
					fmt_type_mismatch(arg_type, param_type, ctx.reg),
					"Use the correct type")
			}
		}
	}

	// Check keyword arg types against matching param types
	for kw in e.keywords {
		kw_type := infer_expr(kw.value, ctx)
		for p in func_info.params {
			if p.name == kw.arg {
				if p.type_id != TYPE_ANY && p.type_id != TYPE_UNKNOWN &&
				   kw_type != TYPE_UNKNOWN && kw_type != TYPE_ANY {
					if !is_assignable(ctx.reg, kw_type, p.type_id) {
						emit_diagnostic(ctx, e.loc, "T002", .Error,
							"Incompatible argument type",
							fmt_type_mismatch(kw_type, p.type_id, ctx.reg),
							"Use the correct type")
					}
				}
				break
			}
		}
	}

	// Infer remaining positional args not checked
	for i := n_params; i < n_args; i += 1 {
		infer_expr(e.args[i], ctx)
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

lookup_attribute :: proc(receiver: Type_ID, attr: string, reg: ^Type_Registry) -> Type_ID {
	if receiver == TYPE_UNKNOWN || receiver == TYPE_ANY { return TYPE_UNKNOWN }

	no_params := make([]Param_Type, 0, reg.allocator)

	// String methods
	if receiver == TYPE_STR {
		switch attr {
		// 0-arg methods returning str
		case "upper", "lower", "strip", "lstrip", "rstrip", "title", "capitalize",
		     "swapcase":
			return make_callable_type(reg, no_params, TYPE_STR)
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
		#partial switch cls_info in cls.info {
		case Class_Type:
			if attr_type, ok := cls_info.attrs[attr]; ok {
				return attr_type
			}
		}
	case Class_Type:
		if attr_type, ok := info.attrs[attr]; ok {
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
	case DataFrame_Type:
		return resolve_dataframe_attr(reg, &info, attr)
	case Series_Type:
		return resolve_series_attr(reg, &info, attr)
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

	// *args
	if args.vararg != nil {
		params[idx] = Param_Type{
			name = args.vararg.arg,
			type_id = TYPE_ANY,
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

	// **kwargs
	if args.kwarg != nil {
		params[idx] = Param_Type{
			name = args.kwarg.arg,
			type_id = TYPE_ANY,
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
		if t, ok := ctx.expr_types[rawptr_from_expr(e.args[0])]; ok { a_type = t }
		b_type := TYPE_UNKNOWN
		if t, ok := ctx.expr_types[rawptr_from_expr(e.args[1])]; ok { b_type = t }

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
		if t, ok := ctx.expr_types[rawptr_from_expr(e.args[0])]; ok { a_type = t }
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
		case "TypedDict":
			return handle_typeddict_call(e, ctx), true
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
	// No overload matched — return TYPE_UNKNOWN
	return TYPE_UNKNOWN
}

overload_sig_matches :: proc(arg_types: []Type_ID, keywords: []parser.Keyword, params: []Param_Type, reg: ^Type_Registry) -> bool {
	total := len(arg_types) + len(keywords)
	required := 0
	for p in params {
		if !p.has_default { required += 1 }
	}
	if total < required || total > len(params) { return false }
	// Check positional args
	for arg_type, i in arg_types {
		if i >= len(params) { return false }
		if arg_type != TYPE_UNKNOWN && arg_type != TYPE_ANY &&
		   params[i].type_id != TYPE_UNKNOWN && params[i].type_id != TYPE_ANY {
			if !is_assignable(reg, arg_type, params[i].type_id) {
				return false
			}
		}
	}
	// Check keyword args
	for kw in keywords {
		found := false
		for p in params {
			if p.name == kw.arg {
				found = true
				break
			}
		}
		if !found { return false }
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
					field_type := resolve_annotation(arg.values[i], ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
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

	return register_type(ctx.reg, TypedDict_Type{name = name, fields = fields, total = total})
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
