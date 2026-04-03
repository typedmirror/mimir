package checker

import "core:mem"
import "core:strings"

import parser "mimir:parser"
import binder "mimir:binder"

// ==================== Built-in Type Name Mapping ====================

Builtin_Names :: struct {
	names: map[string]Type_ID,
}

init_builtins :: proc(reg: ^Type_Registry) -> Builtin_Names {
	b: Builtin_Names
	b.names = make(map[string]Type_ID, 32, reg.allocator)

	// int/float/str/bool registered as Callable constructors in register_builtin_functions
	b.names["bytes"]   = TYPE_BYTES
	b.names["None"]    = TYPE_NONE
	b.names["complex"] = TYPE_COMPLEX
	b.names["object"]  = TYPE_OBJECT

	// Register built-in function signatures (int/str/float/bool set here as callables)
	register_builtin_functions(reg, &b)

	return b
}

// ==================== Built-in Functions ====================

register_builtin_functions :: proc(reg: ^Type_Registry, b: ^Builtin_Names) {
	// len(x) -> int
	len_params := make([]Param_Type, 1, reg.allocator)
	len_params[0] = Param_Type{name = "obj", type_id = TYPE_ANY}
	b.names["len"] = make_callable_type(reg, len_params, TYPE_INT)

	// print(*args) -> None (variadic, 0+ args valid)
	print_params := make([]Param_Type, 1, reg.allocator)
	print_params[0] = Param_Type{name = "args", type_id = TYPE_ANY, has_default = true}
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
	env: ^Type_Env = nil,
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
		// Look up as a symbol reference (user-defined class) — qualified key, no collision
		if sym_id, ok := binder.get_ref(bind_result, rawptr(e)); ok {
			class_type_id: Type_ID
			found_class := false
			if ct, f := reg.class_types[qualify(reg, sym_id)]; f {
				class_type_id = ct
				found_class = true
			}
			if found_class {
				ct := get_type(reg, class_type_id)
				#partial switch _ in ct.info {
				case TypedDict_Type, Protocol_Type:
					return class_type_id
				case:
					return make_instance_type(reg, class_type_id)
				}
			}
			// Check if symbol maps to a TypeVar/TypedDict/Protocol/type alias in environment
			if env != nil {
				if env_type, env_found := env.types[sym_id]; env_found {
					et := get_type(reg, env_type)
					#partial switch info in et.info {
					case TypeVar_Type:      return env_type
					case TypeVarTuple_Type: return env_type
					case TypedDict_Type:    return env_type
					case Protocol_Type:     return env_type
					case Callable_Type:
						// Type alias: MyInt = int → Callable returns int → use return type
						if info.return_type != TYPE_UNKNOWN && info.return_type != TYPE_ANY {
							return info.return_type
						}
					case Class_Type:
						// Class alias: MyClass = Foo → use as instance type
						return make_instance_type(reg, env_type)
					case List_Type, Dict_Type, Set_Type, Tuple_Type, Union_Type:
						// Container/union type alias: Vector = list[float] → use directly
						return env_type
					case Primitive_Type:
						// Primitive alias: MyInt = int → use directly
						return env_type
					case Instance_Type:
						// Instance alias: x = MyClass() used as type → use directly
						return env_type
					}
				}
			}
			// Check typing imports (Any, Never, NoReturn, object, List, Dict, etc.)
			if orig_name, is_typing := bind_result.typing_names[e.id]; is_typing {
				switch orig_name {
				case "Any":            return TYPE_ANY
				case "Never":          return TYPE_NEVER
				case "NoReturn":       return TYPE_NEVER
				case "object":         return TYPE_OBJECT
				case "Self":
					if reg.current_resolve_class != INVALID_TYPE {
						return make_instance_type(reg, reg.current_resolve_class)
					}
					return TYPE_UNKNOWN
				case "Final":     return TYPE_ANY  // Bare Final — type inferred from RHS
				case "ClassVar":  return TYPE_ANY  // Bare ClassVar — type inferred from RHS
				case "List", "list":   return make_list_type(reg, TYPE_ANY)
				case "Dict", "dict":   return make_dict_type(reg, TYPE_ANY, TYPE_ANY)
				case "Set", "set":     return make_set_type(reg, TYPE_ANY)
				case "Tuple", "tuple": return make_tuple_type(reg, {}, false)
				}
			}
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
		// Resolve typing aliases: `from typing import List as L` → L maps to List
		if orig, ok := bind_result.typing_names[base_name]; ok {
			base_name = orig
		}
		switch base_name {
		case "list":
			elem := resolve_annotation(e.slice, reg, bind_result, builtins, env)
			return make_list_type(reg, elem)
		case "List":
			elem := resolve_annotation(e.slice, reg, bind_result, builtins, env)
			return make_list_type(reg, elem)
		case "dict", "Dict":
			key, val := resolve_two_args(e.slice, reg, bind_result, builtins, env)
			return make_dict_type(reg, key, val)
		case "set", "Set":
			elem := resolve_annotation(e.slice, reg, bind_result, builtins, env)
			return make_set_type(reg, elem)
		case "tuple", "Tuple":
			elems := resolve_tuple_args(e.slice, reg, bind_result, builtins, env)
			// Detect Tuple[T, ...] — homogeneous variadic tuple
			is_variadic := false
			if len(elems) == 2 {
				last_t := get_type(reg, elems[1])
				if _, is_unk := last_t.info.(Unknown_Type); is_unk {
					// Ellipsis resolves to Unknown — check if actual AST has Ellipsis
					if tup, tup_ok := e.slice.(^parser.Tuple_Expr); tup_ok {
						if len(tup.elts) == 2 {
							if c, c_ok := tup.elts[1].(^parser.Constant_Expr); c_ok {
								if _, is_ellipsis := c.value.(parser.Const_Ellipsis); is_ellipsis {
									elems = elems[:1]  // Keep just the element type
									is_variadic = true
								}
							}
						}
					}
				}
			}
			return make_tuple_type(reg, elems, is_variadic)
		case "Optional":
			inner := resolve_annotation(e.slice, reg, bind_result, builtins, env)
			members := [2]Type_ID{inner, TYPE_NONE}
			return make_union_type(reg, members[:])
		case "Union":
			args := resolve_tuple_args(e.slice, reg, bind_result, builtins, env)
			return make_union_type(reg, args)
		case "Callable":
			// Callable[[param_types...], return_type]
			#partial switch slice in e.slice {
			case ^parser.Tuple_Expr:
				if len(slice.elts) == 2 {
					ret_type := resolve_annotation(slice.elts[1], reg, bind_result, builtins, env)
					#partial switch params_list in slice.elts[0] {
					case ^parser.List_Expr:
						param_types := make([]Param_Type, len(params_list.elts), reg.allocator)
						for p, i in params_list.elts {
							pt := resolve_annotation(p, reg, bind_result, builtins, env)
							param_types[i] = Param_Type{name = "", type_id = pt}
						}
						return make_callable_type(reg, param_types, ret_type)
					case:
						// Callable[..., ret] — Ellipsis or unparseable params
						return make_callable_type(reg, {}, ret_type)
					}
				}
			}
			return TYPE_ANY
		case "TypeGuard":
			// TypeGuard[T] — returns bool at runtime, but stores T for guard narrowing
			// The target type T is stored on the registry by the Func_Def handler
			resolve_annotation(e.slice, reg, bind_result, builtins, env)
			return TYPE_BOOL
		case "TypeIs":
			// TypeIs[T] (PEP 742) — like TypeGuard but narrows in both branches
			resolve_annotation(e.slice, reg, bind_result, builtins, env)
			return TYPE_BOOL
		case "Final":
			// Final[T] — immutable variable with type T
			return resolve_annotation(e.slice, reg, bind_result, builtins, env)
		case "ClassVar":
			// ClassVar[T] — class-level attribute with type T
			return resolve_annotation(e.slice, reg, bind_result, builtins, env)
		case "Annotated":
			// Annotated[T, metadata...] — extract T, ignore metadata
			#partial switch slice in e.slice {
			case ^parser.Tuple_Expr:
				if len(slice.elts) > 0 {
					return resolve_annotation(slice.elts[0], reg, bind_result, builtins, env)
				}
			}
			return resolve_annotation(e.slice, reg, bind_result, builtins, env)
		case "Required":
			// Required[T] — field is required even in total=False TypedDict
			return resolve_annotation(e.slice, reg, bind_result, builtins, env)
		case "NotRequired":
			// NotRequired[T] — field is optional even in total=True TypedDict
			return resolve_annotation(e.slice, reg, bind_result, builtins, env)
		case "Unpack":
			// Unpack[Ts] — unpack a TypeVarTuple in annotation context
			return resolve_annotation(e.slice, reg, bind_result, builtins, env)
		case "Literal":
			// Literal["read", "write"] or Literal[1, 2] → union of literal types
			return resolve_literal_annotation(e.slice, reg)
		case "type":
			// type[X] → the Class_Type for X (class object, not instance)
			inner := resolve_annotation(e.slice, reg, bind_result, builtins, env)
			// Inner resolves to Instance_Type — unwrap to get Class_Type
			it := get_type(reg, inner)
			#partial switch inst in it.info {
			case Instance_Type:
				return inst.class_type
			case Class_Type:
				return inner
			}
			// Bare type[int] etc. — return TYPE_OBJECT as fallback
			return TYPE_OBJECT
		}
		// User-defined generic class: MyClass[int]
		base_type := resolve_annotation(e.value, reg, bind_result, builtins, env)
		bt := get_type(reg, base_type)
		#partial switch inst in bt.info {
		case Instance_Type:
			cls_t := get_type(reg, inst.class_type)
			#partial switch cls_info in cls_t.info {
			case Class_Type:
				if len(cls_info.type_params) > 0 {
					type_args := resolve_tuple_args(e.slice, reg, bind_result, builtins, env)
					return specialize_class(reg, inst.class_type, type_args)
				}
			}
		}
		return TYPE_UNKNOWN

	case ^parser.Bin_Op_Expr:
		// int | str → Union
		if e.op == .Bit_Or {
			left := resolve_annotation(e.left, reg, bind_result, builtins, env)
			right := resolve_annotation(e.right, reg, bind_result, builtins, env)
			members := [2]Type_ID{left, right}
			return make_union_type(reg, members[:])
		}
		return TYPE_UNKNOWN

	case ^parser.Starred_Expr:
		// *Ts — PEP 646 TypeVarTuple unpacking in annotations (Python 3.11+)
		return resolve_annotation(e.value, reg, bind_result, builtins, env)

	case ^parser.Constant_Expr:
		// None as annotation
		if _, is_none := e.value.(parser.Const_None); is_none {
			return TYPE_NONE
		}
		// String annotation (forward reference): "Foo" → look up class name
		if str_val, is_str := e.value.(string); is_str {
			// Try built-in type names
			switch str_val {
			case "int":   return TYPE_INT
			case "str":   return TYPE_STR
			case "float": return TYPE_FLOAT
			case "bool":  return TYPE_BOOL
			case "bytes": return TYPE_BYTES
			case "None":  return TYPE_NONE
			}
			// Handle "X | Y" union syntax in string annotations
			if strings.contains(str_val, " | ") {
				parts := strings.split(str_val, " | ", allocator = reg.allocator)
				if len(parts) >= 2 {
					members := make([dynamic]Type_ID, 0, len(parts), reg.allocator)
					for part in parts {
						p := strings.trim_space(part)
						pt := resolve_string_type_name(p, reg)
						if pt != TYPE_UNKNOWN {
							append(&members, pt)
						}
					}
					if len(members) >= 2 {
						return make_union_type(reg, members[:])
					} else if len(members) == 1 {
						return members[0]
					}
				}
			}
			// Try class name lookup in registry
			for _, class_type_id in reg.class_types {
				ct := get_type(reg, class_type_id)
				#partial switch cls in ct.info {
				case Class_Type:
					if cls.name == str_val {
						return make_instance_type(reg, class_type_id)
					}
				}
			}
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

// Check if an annotation is Final or Final[T]
is_final_annotation :: proc(expr: parser.Expr, bind_result: ^binder.Bind_Result) -> bool {
	if expr == nil { return false }
	#partial switch e in expr {
	case ^parser.Name_Expr:
		if orig, ok := bind_result.typing_names[e.id]; ok {
			return orig == "Final"
		}
	case ^parser.Subscript_Expr:
		base_name := get_annotation_name(e.value)
		if orig, ok := bind_result.typing_names[base_name]; ok {
			return orig == "Final"
		}
	}
	return false
}

// Check if an annotation is Required[T]
is_required_annotation :: proc(expr: parser.Expr, bind_result: ^binder.Bind_Result) -> bool {
	if expr == nil { return false }
	#partial switch e in expr {
	case ^parser.Subscript_Expr:
		base_name := get_annotation_name(e.value)
		if orig, ok := bind_result.typing_names[base_name]; ok {
			return orig == "Required"
		}
	}
	return false
}

// Check if an annotation is NotRequired[T]
is_notrequired_annotation :: proc(expr: parser.Expr, bind_result: ^binder.Bind_Result) -> bool {
	if expr == nil { return false }
	#partial switch e in expr {
	case ^parser.Subscript_Expr:
		base_name := get_annotation_name(e.value)
		if orig, ok := bind_result.typing_names[base_name]; ok {
			return orig == "NotRequired"
		}
	}
	return false
}

// Resolve Literal[...] annotation → Literal types or union thereof
resolve_literal_annotation :: proc(expr: parser.Expr, reg: ^Type_Registry) -> Type_ID {
	if expr == nil { return TYPE_UNKNOWN }
	// Single value: Literal[42] or Literal["read"]
	lit_type := resolve_literal_value(expr, reg)
	if lit_type != TYPE_UNKNOWN { return lit_type }
	// Multiple values: Literal["read", "write"] → union
	#partial switch e in expr {
	case ^parser.Tuple_Expr:
		members := make([dynamic]Type_ID, 0, len(e.elts), reg.allocator)
		for elt in e.elts {
			lt := resolve_literal_value(elt, reg)
			if lt != TYPE_UNKNOWN {
				append(&members, lt)
			}
		}
		if len(members) == 0 { return TYPE_UNKNOWN }
		if len(members) == 1 { return members[0] }
		return make_union_type(reg, members[:])
	}
	return TYPE_UNKNOWN
}

// Resolve a single constant expression to a Literal type
resolve_literal_value :: proc(expr: parser.Expr, reg: ^Type_Registry) -> Type_ID {
	if expr == nil { return TYPE_UNKNOWN }
	#partial switch e in expr {
	case ^parser.Constant_Expr:
		#partial switch v in e.value {
		case i64:    return register_type(reg, Literal_Int_Type{value = v})
		case string: return register_type(reg, Literal_Str_Type{value = v})
		case bool:   return register_type(reg, Literal_Bool_Type{value = v})
		}
	case ^parser.Unary_Op_Expr:
		// Literal[-1] → negate
		if e.op == .USub {
			if c, ok := e.operand.(^parser.Constant_Expr); ok {
				if val, is_int := c.value.(i64); is_int {
					return register_type(reg, Literal_Int_Type{value = -val})
				}
			}
		}
	case ^parser.Name_Expr:
		// Literal[True] / Literal[False] / Literal[None]
		switch e.id {
		case "True":  return register_type(reg, Literal_Bool_Type{value = true})
		case "False": return register_type(reg, Literal_Bool_Type{value = false})
		case "None":  return TYPE_NONE
		}
	}
	return TYPE_UNKNOWN
}

// Resolve a simple type name from a string annotation component (for "X | Y" parsing)
resolve_string_type_name :: proc(name: string, reg: ^Type_Registry) -> Type_ID {
	switch name {
	case "int":    return TYPE_INT
	case "str":    return TYPE_STR
	case "float":  return TYPE_FLOAT
	case "bool":   return TYPE_BOOL
	case "bytes":  return TYPE_BYTES
	case "None":   return TYPE_NONE
	case "object": return TYPE_OBJECT
	case "Any":    return TYPE_ANY
	case "Never":  return TYPE_NEVER
	}
	// Try class name lookup
	for _, class_type_id in reg.class_types {
		ct := get_type(reg, class_type_id)
		#partial switch cls in ct.info {
		case Class_Type:
			if cls.name == name {
				return make_instance_type(reg, class_type_id)
			}
		}
	}
	return TYPE_UNKNOWN
}

// Helper: resolve two generic args from a Tuple_Expr (for dict[K, V])
resolve_two_args :: proc(
	expr: parser.Expr,
	reg: ^Type_Registry,
	bind_result: ^binder.Bind_Result,
	builtins: ^Builtin_Names,
	env: ^Type_Env = nil,
) -> (Type_ID, Type_ID) {
	#partial switch e in expr {
	case ^parser.Tuple_Expr:
		if len(e.elts) >= 2 {
			k := resolve_annotation(e.elts[0], reg, bind_result, builtins, env)
			v := resolve_annotation(e.elts[1], reg, bind_result, builtins, env)
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
	env: ^Type_Env = nil,
) -> []Type_ID {
	#partial switch e in expr {
	case ^parser.Tuple_Expr:
		result := make([]Type_ID, len(e.elts), reg.allocator)
		for elt, i in e.elts {
			result[i] = resolve_annotation(elt, reg, bind_result, builtins, env)
		}
		return result
	}
	// Single arg
	single := make([]Type_ID, 1, reg.allocator)
	single[0] = resolve_annotation(expr, reg, bind_result, builtins, env)
	return single
}
