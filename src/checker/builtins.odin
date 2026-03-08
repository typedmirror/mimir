package checker

import "core:mem"

import parser "mimir:parser"
import binder "mimir:binder"

// ==================== Built-in Type Name Mapping ====================

Builtin_Names :: struct {
	names: map[string]Type_ID,
}

init_builtins :: proc(reg: ^Type_Registry) -> Builtin_Names {
	b: Builtin_Names
	b.names = make(map[string]Type_ID, 32, reg.allocator)

	b.names["int"]     = TYPE_INT
	b.names["float"]   = TYPE_FLOAT
	b.names["str"]     = TYPE_STR
	b.names["bytes"]   = TYPE_BYTES
	b.names["bool"]    = TYPE_BOOL
	b.names["None"]    = TYPE_NONE
	b.names["complex"] = TYPE_COMPLEX
	b.names["object"]  = TYPE_OBJECT

	// Register built-in function signatures
	register_builtin_functions(reg, &b)

	return b
}

// ==================== Built-in Functions ====================

register_builtin_functions :: proc(reg: ^Type_Registry, b: ^Builtin_Names) {
	// len(x) -> int
	len_params := make([]Param_Type, 1, reg.allocator)
	len_params[0] = Param_Type{name = "obj", type_id = TYPE_ANY}
	b.names["len"] = make_callable_type(reg, len_params, TYPE_INT)

	// print(*args) -> None
	print_params := make([]Param_Type, 1, reg.allocator)
	print_params[0] = Param_Type{name = "args", type_id = TYPE_ANY}
	b.names["print"] = make_callable_type(reg, print_params, TYPE_NONE)

	// range(stop) -> range (approximate as list[int] for iteration)
	range_params := make([]Param_Type, 3, reg.allocator)
	range_params[0] = Param_Type{name = "start", type_id = TYPE_INT}
	range_params[1] = Param_Type{name = "stop", type_id = TYPE_INT, has_default = true}
	range_params[2] = Param_Type{name = "step", type_id = TYPE_INT, has_default = true}
	b.names["range"] = make_callable_type(reg, range_params, make_list_type(reg, TYPE_INT))

	// isinstance(obj, classinfo) -> bool
	isinstance_params := make([]Param_Type, 2, reg.allocator)
	isinstance_params[0] = Param_Type{name = "obj", type_id = TYPE_ANY}
	isinstance_params[1] = Param_Type{name = "classinfo", type_id = TYPE_ANY}
	b.names["isinstance"] = make_callable_type(reg, isinstance_params, TYPE_BOOL)

	// type(obj) -> type
	type_params := make([]Param_Type, 1, reg.allocator)
	type_params[0] = Param_Type{name = "obj", type_id = TYPE_ANY}
	b.names["type"] = make_callable_type(reg, type_params, TYPE_OBJECT)

	// int(x) -> int, str(x) -> str, float(x) -> float, bool(x) -> bool
	// These shadow the type names as constructors — handled in resolve_annotation
	// The callable versions:
	int_params := make([]Param_Type, 1, reg.allocator)
	int_params[0] = Param_Type{name = "x", type_id = TYPE_ANY, has_default = true}
	b.names["int"] = make_callable_type(reg, int_params, TYPE_INT)

	str_params := make([]Param_Type, 1, reg.allocator)
	str_params[0] = Param_Type{name = "x", type_id = TYPE_ANY, has_default = true}
	b.names["str"] = make_callable_type(reg, str_params, TYPE_STR)

	float_params := make([]Param_Type, 1, reg.allocator)
	float_params[0] = Param_Type{name = "x", type_id = TYPE_ANY, has_default = true}
	b.names["float"] = make_callable_type(reg, float_params, TYPE_FLOAT)

	bool_params := make([]Param_Type, 1, reg.allocator)
	bool_params[0] = Param_Type{name = "x", type_id = TYPE_ANY, has_default = true}
	b.names["bool"] = make_callable_type(reg, bool_params, TYPE_BOOL)

	// abs(x) -> x (approximate as Any -> Any)
	abs_params := make([]Param_Type, 1, reg.allocator)
	abs_params[0] = Param_Type{name = "x", type_id = TYPE_ANY}
	b.names["abs"] = make_callable_type(reg, abs_params, TYPE_ANY)

	// enumerate(iterable) -> list[tuple[int, T]] (approximate)
	enum_params := make([]Param_Type, 1, reg.allocator)
	enum_params[0] = Param_Type{name = "iterable", type_id = TYPE_ANY}
	b.names["enumerate"] = make_callable_type(reg, enum_params, TYPE_ANY)

	// zip(*iterables) -> list[tuple] (approximate)
	zip_params := make([]Param_Type, 1, reg.allocator)
	zip_params[0] = Param_Type{name = "iterables", type_id = TYPE_ANY}
	b.names["zip"] = make_callable_type(reg, zip_params, TYPE_ANY)

	// sorted(iterable) -> list
	sorted_params := make([]Param_Type, 1, reg.allocator)
	sorted_params[0] = Param_Type{name = "iterable", type_id = TYPE_ANY}
	b.names["sorted"] = make_callable_type(reg, sorted_params, TYPE_ANY)

	// reversed(seq) -> iterator
	reversed_params := make([]Param_Type, 1, reg.allocator)
	reversed_params[0] = Param_Type{name = "seq", type_id = TYPE_ANY}
	b.names["reversed"] = make_callable_type(reg, reversed_params, TYPE_ANY)

	// min/max(*args) -> Any
	min_params := make([]Param_Type, 1, reg.allocator)
	min_params[0] = Param_Type{name = "args", type_id = TYPE_ANY}
	b.names["min"] = make_callable_type(reg, min_params, TYPE_ANY)

	max_params := make([]Param_Type, 1, reg.allocator)
	max_params[0] = Param_Type{name = "args", type_id = TYPE_ANY}
	b.names["max"] = make_callable_type(reg, max_params, TYPE_ANY)

	// sum(iterable) -> int|float
	sum_params := make([]Param_Type, 1, reg.allocator)
	sum_params[0] = Param_Type{name = "iterable", type_id = TYPE_ANY}
	b.names["sum"] = make_callable_type(reg, sum_params, TYPE_INT)

	// input(prompt) -> str
	input_params := make([]Param_Type, 1, reg.allocator)
	input_params[0] = Param_Type{name = "prompt", type_id = TYPE_STR, has_default = true}
	b.names["input"] = make_callable_type(reg, input_params, TYPE_STR)

	// repr(obj) -> str
	repr_params := make([]Param_Type, 1, reg.allocator)
	repr_params[0] = Param_Type{name = "obj", type_id = TYPE_ANY}
	b.names["repr"] = make_callable_type(reg, repr_params, TYPE_STR)

	// hash(obj) -> int
	hash_params := make([]Param_Type, 1, reg.allocator)
	hash_params[0] = Param_Type{name = "obj", type_id = TYPE_ANY}
	b.names["hash"] = make_callable_type(reg, hash_params, TYPE_INT)

	// id(obj) -> int
	id_params := make([]Param_Type, 1, reg.allocator)
	id_params[0] = Param_Type{name = "obj", type_id = TYPE_ANY}
	b.names["id"] = make_callable_type(reg, id_params, TYPE_INT)

	// super() -> object
	super_params := make([]Param_Type, 0, reg.allocator)
	b.names["super"] = make_callable_type(reg, super_params, TYPE_OBJECT)

	// open(file, mode) -> Any
	open_params := make([]Param_Type, 2, reg.allocator)
	open_params[0] = Param_Type{name = "file", type_id = TYPE_STR}
	open_params[1] = Param_Type{name = "mode", type_id = TYPE_STR, has_default = true}
	b.names["open"] = make_callable_type(reg, open_params, TYPE_ANY)
}

// ==================== Annotation Resolution ====================

// Resolve a type annotation expression to a Type_ID
resolve_annotation :: proc(
	expr: parser.Expr,
	reg: ^Type_Registry,
	bind_result: ^binder.Bind_Result,
	builtins: ^Builtin_Names,
) -> Type_ID {
	if expr == nil { return TYPE_UNKNOWN }

	#partial switch e in expr {
	case ^parser.Name_Expr:
		// Check built-in type names: "int", "str", "float", etc.
		if tid, ok := builtins.names[e.id]; ok {
			// For constructor callables (int, str, etc.), return the primitive type in annotation context
			switch e.id {
			case "int":   return TYPE_INT
			case "str":   return TYPE_STR
			case "float": return TYPE_FLOAT
			case "bool":  return TYPE_BOOL
			case "bytes": return TYPE_BYTES
			case "None":  return TYPE_NONE
			case "object": return TYPE_OBJECT
			case:
				// Could be a class type — look up in binder
				_ = tid
			}
		}
		// Look up as a symbol reference (user-defined class)
		if sym_id, ok := binder.get_ref(bind_result, rawptr(e)); ok {
			_ = sym_id
			// For now, return UNKNOWN for user-defined types not yet handled
			return TYPE_UNKNOWN
		}
		// Special names
		switch e.id {
		case "None": return TYPE_NONE
		case "Any":  return TYPE_ANY
		}
		return TYPE_UNKNOWN

	case ^parser.Subscript_Expr:
		// Generic types: list[int], dict[str, int], Optional[int], etc.
		base_name := get_annotation_name(e.value)
		switch base_name {
		case "list":
			elem := resolve_annotation(e.slice, reg, bind_result, builtins)
			return make_list_type(reg, elem)
		case "List":
			elem := resolve_annotation(e.slice, reg, bind_result, builtins)
			return make_list_type(reg, elem)
		case "dict", "Dict":
			// dict[K, V] — slice is a Tuple_Expr with two elements
			key, val := resolve_two_args(e.slice, reg, bind_result, builtins)
			return make_dict_type(reg, key, val)
		case "set", "Set":
			elem := resolve_annotation(e.slice, reg, bind_result, builtins)
			return make_set_type(reg, elem)
		case "tuple", "Tuple":
			elems := resolve_tuple_args(e.slice, reg, bind_result, builtins)
			return make_tuple_type(reg, elems, false)
		case "Optional":
			inner := resolve_annotation(e.slice, reg, bind_result, builtins)
			members := [2]Type_ID{inner, TYPE_NONE}
			return make_union_type(reg, members[:])
		case "Union":
			args := resolve_tuple_args(e.slice, reg, bind_result, builtins)
			return make_union_type(reg, args)
		case "Callable":
			// Simplified: Callable[[params], return_type]
			return TYPE_ANY // Detailed callable parsing deferred
		}
		return TYPE_UNKNOWN

	case ^parser.Bin_Op_Expr:
		// int | str → Union
		if e.op == .Bit_Or {
			left := resolve_annotation(e.left, reg, bind_result, builtins)
			right := resolve_annotation(e.right, reg, bind_result, builtins)
			members := [2]Type_ID{left, right}
			return make_union_type(reg, members[:])
		}
		return TYPE_UNKNOWN

	case ^parser.Constant_Expr:
		// None as annotation
		if _, is_none := e.value.(parser.Const_None); is_none {
			return TYPE_NONE
		}
		return TYPE_UNKNOWN

	case ^parser.Attribute_Expr:
		// typing.Optional, typing.List, etc.
		attr_name := e.attr
		switch attr_name {
		case "Optional":
			return TYPE_UNKNOWN // Would need subscript
		case "Any":
			return TYPE_ANY
		}
		return TYPE_UNKNOWN
	}

	return TYPE_UNKNOWN
}

// Helper: get the name from a Name_Expr or Attribute_Expr
get_annotation_name :: proc(expr: parser.Expr) -> string {
	#partial switch e in expr {
	case ^parser.Name_Expr:
		return e.id
	case ^parser.Attribute_Expr:
		return e.attr
	}
	return ""
}

// Helper: resolve two generic args from a Tuple_Expr (for dict[K, V])
resolve_two_args :: proc(
	expr: parser.Expr,
	reg: ^Type_Registry,
	bind_result: ^binder.Bind_Result,
	builtins: ^Builtin_Names,
) -> (Type_ID, Type_ID) {
	#partial switch e in expr {
	case ^parser.Tuple_Expr:
		if len(e.elts) >= 2 {
			k := resolve_annotation(e.elts[0], reg, bind_result, builtins)
			v := resolve_annotation(e.elts[1], reg, bind_result, builtins)
			return k, v
		}
	}
	return TYPE_UNKNOWN, TYPE_UNKNOWN
}

// Helper: resolve tuple generic args
resolve_tuple_args :: proc(
	expr: parser.Expr,
	reg: ^Type_Registry,
	bind_result: ^binder.Bind_Result,
	builtins: ^Builtin_Names,
) -> []Type_ID {
	#partial switch e in expr {
	case ^parser.Tuple_Expr:
		result := make([]Type_ID, len(e.elts), reg.allocator)
		for elt, i in e.elts {
			result[i] = resolve_annotation(elt, reg, bind_result, builtins)
		}
		return result
	}
	// Single arg
	single := make([]Type_ID, 1, reg.allocator)
	single[0] = resolve_annotation(expr, reg, bind_result, builtins)
	return single
}
