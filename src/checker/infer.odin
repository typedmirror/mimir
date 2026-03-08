package checker

import "core:mem"

import parser "mimir:parser"
import binder "mimir:binder"
import core "mimir:core"

// ==================== Expression Type Inference ====================

Infer_Context :: struct {
	env:         ^Type_Env,
	reg:         ^Type_Registry,
	bind_result: ^binder.Bind_Result,
	builtins:    ^Builtin_Names,
	expr_types:  ^map[rawptr]Type_ID,
	diagnostics: ^[dynamic]core.Diagnostic,
	file_path:   string,
}

infer_expr :: proc(expr: parser.Expr, ctx: ^Infer_Context) -> Type_ID {
	if expr == nil { return TYPE_UNKNOWN }

	result := infer_expr_inner(expr, ctx)

	// Record in expr_types map
	ctx.expr_types[expr_to_rawptr(expr)] = result

	return result
}

infer_expr_inner :: proc(expr: parser.Expr, ctx: ^Infer_Context) -> Type_ID {
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
		return result

	case ^parser.Unary_Op_Expr:
		operand := infer_expr(e.operand, ctx)
		return infer_unaryop(e.op, operand, ctx.reg)

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
			append(&types, infer_expr(v, ctx))
		}
		return make_union_type(ctx.reg, types[:])

	case ^parser.Call_Expr:
		return infer_call(e, ctx)

	case ^parser.Attribute_Expr:
		receiver := infer_expr(e.value, ctx)
		return lookup_attribute(receiver, e.attr, ctx.reg)

	case ^parser.Subscript_Expr:
		container := infer_expr(e.value, ctx)
		infer_expr(e.slice, ctx) // type-check the index
		return get_subscript_type(container, ctx.reg)

	case ^parser.List_Expr:
		if len(e.elts) == 0 {
			return make_list_type(ctx.reg, TYPE_UNKNOWN)
		}
		elem_types := make([dynamic]Type_ID, 0, len(e.elts), ctx.reg.allocator)
		for elt in e.elts {
			append(&elem_types, infer_expr(elt, ctx))
		}
		elem := unify_types(elem_types[:], ctx.reg)
		return make_list_type(ctx.reg, elem)

	case ^parser.Dict_Expr:
		if len(e.keys) == 0 {
			return make_dict_type(ctx.reg, TYPE_UNKNOWN, TYPE_UNKNOWN)
		}
		key_types := make([dynamic]Type_ID, 0, len(e.keys), ctx.reg.allocator)
		val_types := make([dynamic]Type_ID, 0, len(e.values), ctx.reg.allocator)
		for k in e.keys {
			append(&key_types, infer_expr(k, ctx))
		}
		for v in e.values {
			append(&val_types, infer_expr(v, ctx))
		}
		key := unify_types(key_types[:], ctx.reg)
		val := unify_types(val_types[:], ctx.reg)
		return make_dict_type(ctx.reg, key, val)

	case ^parser.Set_Expr:
		if len(e.elts) == 0 {
			return make_set_type(ctx.reg, TYPE_UNKNOWN)
		}
		elem_types := make([dynamic]Type_ID, 0, len(e.elts), ctx.reg.allocator)
		for elt in e.elts {
			append(&elem_types, infer_expr(elt, ctx))
		}
		elem := unify_types(elem_types[:], ctx.reg)
		return make_set_type(ctx.reg, elem)

	case ^parser.Tuple_Expr:
		elem_types := make([]Type_ID, len(e.elts), ctx.reg.allocator)
		for elt, i in e.elts {
			elem_types[i] = infer_expr(elt, ctx)
		}
		return make_tuple_type(ctx.reg, elem_types, false)

	case ^parser.If_Expr:
		infer_expr(e.test, ctx)
		body_type := infer_expr(e.body, ctx)
		else_type := infer_expr(e.orelse, ctx)
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
		return infer_expr(e.value, ctx)

	case ^parser.Yield_Expr:
		if e.value != nil {
			return infer_expr(e.value, ctx)
		}
		return TYPE_NONE

	case ^parser.Yield_From_Expr:
		return infer_expr(e.value, ctx)

	case ^parser.List_Comp:
		return make_list_type(ctx.reg, TYPE_UNKNOWN)
	case ^parser.Set_Comp:
		return make_set_type(ctx.reg, TYPE_UNKNOWN)
	case ^parser.Dict_Comp:
		return make_dict_type(ctx.reg, TYPE_UNKNOWN, TYPE_UNKNOWN)
	case ^parser.Generator_Expr:
		return TYPE_ANY

	case ^parser.Formatted_Value:
		return TYPE_STR
	case ^parser.Joined_Str:
		return TYPE_STR

	case ^parser.Slice_Expr:
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

	switch op {
	case .Add:
		if left == TYPE_INT && right == TYPE_INT { return TYPE_INT }
		if is_numeric(reg, left) && is_numeric(reg, right) { return TYPE_FLOAT }
		if left == TYPE_STR && right == TYPE_STR { return TYPE_STR }
		if is_list_type(reg, left) && is_list_type(reg, right) { return left }
		// bool + bool = int (Python promotes)
		if left == TYPE_BOOL && right == TYPE_BOOL { return TYPE_INT }

	case .Sub, .Mult:
		if left == TYPE_INT && right == TYPE_INT { return TYPE_INT }
		if is_numeric(reg, left) && is_numeric(reg, right) { return TYPE_FLOAT }
		// str * int or int * str
		if op == .Mult {
			if left == TYPE_STR && right == TYPE_INT { return TYPE_STR }
			if left == TYPE_INT && right == TYPE_STR { return TYPE_STR }
		}

	case .Div:
		if is_numeric(reg, left) && is_numeric(reg, right) { return TYPE_FLOAT }

	case .Floor_Div, .Mod:
		if left == TYPE_INT && right == TYPE_INT { return TYPE_INT }
		if is_numeric(reg, left) && is_numeric(reg, right) { return TYPE_FLOAT }

	case .Pow:
		if left == TYPE_INT && right == TYPE_INT { return TYPE_INT }
		if is_numeric(reg, left) && is_numeric(reg, right) { return TYPE_FLOAT }

	case .LShift, .RShift, .Bit_And, .Bit_Xor:
		if left == TYPE_INT && right == TYPE_INT { return TYPE_INT }

	case .Bit_Or:
		if left == TYPE_INT && right == TYPE_INT { return TYPE_INT }
		if is_set_type(reg, left) && is_set_type(reg, right) { return left }

	case .Mat_Mult:
		return TYPE_UNKNOWN
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

infer_call :: proc(e: ^parser.Call_Expr, ctx: ^Infer_Context) -> Type_ID {
	func_type := infer_expr(e.func, ctx)

	if func_type == TYPE_UNKNOWN || func_type == TYPE_ANY {
		// Still type-check args
		for arg in e.args {
			infer_expr(arg, ctx)
		}
		return TYPE_UNKNOWN
	}

	ft := get_type(ctx.reg, func_type)
	#partial switch &info in ft.info {
	case Callable_Type:
		check_call_args(e, &info, ctx)
		return info.return_type

	case Class_Type:
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

	// Check arg count
	n_args := len(e.args)
	n_params := len(func_info.params)

	if n_args < required {
		emit_diagnostic(ctx, e.loc, "T004", .Error,
			"Too few arguments",
			fmt_arg_count_error(required, n_args, ctx.reg),
			"Add missing arguments")
	} else if n_args > n_params {
		if n_params == 0 {
			emit_diagnostic(ctx, e.loc, "T004", .Error,
				"Too many arguments",
				fmt_arg_count_error(n_params, n_args, ctx.reg),
				"Remove extra arguments")
		} else {
			// Check if last param is *args (has_default used as approximation)
			last := func_info.params[n_params - 1]
			if last.type_id != TYPE_ANY { // non-variadic
				emit_diagnostic(ctx, e.loc, "T004", .Error,
					"Too many arguments",
					fmt_arg_count_error(n_params, n_args, ctx.reg),
					"Remove extra arguments")
			}
		}
	}

	// Check arg types against param types
	for i := 0; i < min(n_args, n_params); i += 1 {
		arg_type := infer_expr(e.args[i], ctx)
		param_type := func_info.params[i].type_id
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

	// Infer remaining args not checked
	for i := n_params; i < n_args; i += 1 {
		infer_expr(e.args[i], ctx)
	}
}

// ==================== Attribute Lookup ====================

lookup_attribute :: proc(receiver: Type_ID, attr: string, reg: ^Type_Registry) -> Type_ID {
	if receiver == TYPE_UNKNOWN || receiver == TYPE_ANY { return TYPE_UNKNOWN }

	// String methods
	if receiver == TYPE_STR {
		switch attr {
		case "upper", "lower", "strip", "lstrip", "rstrip", "title", "capitalize",
		     "swapcase", "replace", "join", "format", "center", "ljust", "rjust",
		     "zfill", "encode":
			return make_callable_type(reg,
				make([]Param_Type, 0, reg.allocator), TYPE_STR)
		case "split", "rsplit", "splitlines":
			return make_callable_type(reg,
				make([]Param_Type, 0, reg.allocator), make_list_type(reg, TYPE_STR))
		case "find", "rfind", "index", "rindex", "count":
			return make_callable_type(reg,
				make([]Param_Type, 0, reg.allocator), TYPE_INT)
		case "startswith", "endswith", "isdigit", "isalpha", "isalnum",
		     "isspace", "isupper", "islower", "istitle", "isnumeric",
		     "isidentifier", "isprintable", "isascii", "isdecimal":
			return make_callable_type(reg,
				make([]Param_Type, 0, reg.allocator), TYPE_BOOL)
		}
	}

	// List methods
	if is_list_type(reg, receiver) {
		elem := get_list_element(reg, receiver)
		switch attr {
		case "append", "extend", "insert", "remove", "clear",
		     "reverse", "sort":
			return make_callable_type(reg,
				make([]Param_Type, 0, reg.allocator), TYPE_NONE)
		case "pop":
			return make_callable_type(reg,
				make([]Param_Type, 0, reg.allocator), elem)
		case "index", "count":
			return make_callable_type(reg,
				make([]Param_Type, 0, reg.allocator), TYPE_INT)
		case "copy":
			return make_callable_type(reg,
				make([]Param_Type, 0, reg.allocator), receiver)
		}
	}

	// Dict methods
	if is_dict_type(reg, receiver) {
		t := get_type(reg, receiver)
		#partial switch info in t.info {
		case Dict_Type:
			switch attr {
			case "keys":
				return make_callable_type(reg,
					make([]Param_Type, 0, reg.allocator), TYPE_ANY)
			case "values":
				return make_callable_type(reg,
					make([]Param_Type, 0, reg.allocator), TYPE_ANY)
			case "items":
				return make_callable_type(reg,
					make([]Param_Type, 0, reg.allocator), TYPE_ANY)
			case "get":
				return make_callable_type(reg,
					make([]Param_Type, 0, reg.allocator), info.value)
			case "pop":
				return make_callable_type(reg,
					make([]Param_Type, 0, reg.allocator), info.value)
			case "update", "clear":
				return make_callable_type(reg,
					make([]Param_Type, 0, reg.allocator), TYPE_NONE)
			case "copy":
				return make_callable_type(reg,
					make([]Param_Type, 0, reg.allocator), receiver)
			}
		}
	}

	// Instance attribute lookup
	t := get_type(reg, receiver)
	#partial switch info in t.info {
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
	}
	if container == TYPE_STR { return TYPE_STR }
	if container == TYPE_BYTES { return TYPE_INT }
	return TYPE_UNKNOWN
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

	// Position-only args
	for a in args.posonlyargs {
		params[idx] = Param_Type{
			name = a.arg,
			type_id = resolve_annotation(a.annotation, ctx.reg, ctx.bind_result, ctx.builtins),
		}
		idx += 1
	}

	// Regular args
	n_defaults := len(args.defaults)
	n_args := len(args.args)
	for a, i in args.args {
		has_default := i >= (n_args - n_defaults)
		params[idx] = Param_Type{
			name = a.arg,
			type_id = resolve_annotation(a.annotation, ctx.reg, ctx.bind_result, ctx.builtins),
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
		}
		idx += 1
	}

	// Keyword-only args
	for a, i in args.kwonlyargs {
		has_default := i < len(args.kw_defaults) && args.kw_defaults[i] != nil
		params[idx] = Param_Type{
			name = a.arg,
			type_id = resolve_annotation(a.annotation, ctx.reg, ctx.bind_result, ctx.builtins),
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
		}
		idx += 1
	}

	return params[:idx]
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
