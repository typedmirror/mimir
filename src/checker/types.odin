package checker

import "core:mem"
import "core:fmt"
import "core:hash"
import "core:slice"

import binder "mimir:binder"

// ==================== Type ID ====================

Type_ID :: distinct u32

INVALID_TYPE :: Type_ID(0)

// Pre-allocated singleton IDs for built-in types
TYPE_INT     :: Type_ID(1)
TYPE_FLOAT   :: Type_ID(2)
TYPE_STR     :: Type_ID(3)
TYPE_BYTES   :: Type_ID(4)
TYPE_BOOL    :: Type_ID(5)
TYPE_NONE    :: Type_ID(6)
TYPE_COMPLEX :: Type_ID(7)
TYPE_ANY     :: Type_ID(8)
TYPE_UNKNOWN :: Type_ID(9)
TYPE_NEVER   :: Type_ID(10)
TYPE_OBJECT  :: Type_ID(11)
BUILTIN_COUNT :: 12

// ==================== Type Representation ====================

Type :: struct {
	id:   Type_ID,
	info: Type_Info,
}

Type_Info :: union {
	Primitive_Type,
	Any_Type,
	Unknown_Type,
	Never_Type,
	Union_Type,
	Callable_Type,
	List_Type,
	Dict_Type,
	Set_Type,
	Tuple_Type,
	Class_Type,
	Instance_Type,
	Literal_Int_Type,
	Literal_Str_Type,
	Literal_Bool_Type,
	Module_Type,
}

Primitive_Kind :: enum u8 {
	Int, Float, Str, Bytes, Bool, None_Type, Complex, Object,
}

Primitive_Type     :: struct { kind: Primitive_Kind }
Any_Type           :: struct {}
Unknown_Type       :: struct {}
Never_Type         :: struct {}

Union_Type :: struct {
	members: []Type_ID,
}

Callable_Type :: struct {
	params:      []Param_Type,
	return_type: Type_ID,
}

Param_Type :: struct {
	name:        string,
	type_id:     Type_ID,
	has_default: bool,
}

List_Type :: struct { element: Type_ID }
Dict_Type :: struct { key: Type_ID, value: Type_ID }
Set_Type  :: struct { element: Type_ID }

Tuple_Type :: struct {
	elements:    []Type_ID,
	is_variadic: bool,
}

Class_Type :: struct {
	name:      string,
	symbol_id: binder.Symbol_ID,
	scope_id:  binder.Scope_ID,
	bases:     []Type_ID,
	attrs:     map[string]Type_ID,
}

Instance_Type :: struct {
	class_type: Type_ID,
}

Literal_Int_Type  :: struct { value: i64 }
Literal_Str_Type  :: struct { value: string }
Literal_Bool_Type :: struct { value: bool }

Module_Type :: struct {
	scope_id: binder.Scope_ID,
}

// ==================== Type Environment ====================

Type_Env :: struct {
	types: map[binder.Symbol_ID]Type_ID,
}

// ==================== Type Registry ====================

Type_Registry :: struct {
	types:       [dynamic]Type,
	union_cache: map[u64]Type_ID,
	list_cache:  map[Type_ID]Type_ID,
	dict_cache:  map[[2]Type_ID]Type_ID,
	set_cache:   map[Type_ID]Type_ID,
	allocator:   mem.Allocator,
}

init_registry :: proc(allocator: mem.Allocator) -> Type_Registry {
	reg: Type_Registry
	reg.allocator = allocator
	reg.types = make([dynamic]Type, 0, 256, allocator)
	reg.union_cache = make(map[u64]Type_ID, 64, allocator)
	reg.list_cache = make(map[Type_ID]Type_ID, 16, allocator)
	reg.dict_cache = make(map[[2]Type_ID]Type_ID, 16, allocator)
	reg.set_cache = make(map[Type_ID]Type_ID, 16, allocator)

	// Slot 0: INVALID
	append(&reg.types, Type{id = INVALID_TYPE})
	// Slot 1-7: Primitives
	append(&reg.types, Type{id = TYPE_INT,     info = Primitive_Type{.Int}})
	append(&reg.types, Type{id = TYPE_FLOAT,   info = Primitive_Type{.Float}})
	append(&reg.types, Type{id = TYPE_STR,     info = Primitive_Type{.Str}})
	append(&reg.types, Type{id = TYPE_BYTES,   info = Primitive_Type{.Bytes}})
	append(&reg.types, Type{id = TYPE_BOOL,    info = Primitive_Type{.Bool}})
	append(&reg.types, Type{id = TYPE_NONE,    info = Primitive_Type{.None_Type}})
	append(&reg.types, Type{id = TYPE_COMPLEX, info = Primitive_Type{.Complex}})
	// Slot 8-11: Special types
	append(&reg.types, Type{id = TYPE_ANY,     info = Any_Type{}})
	append(&reg.types, Type{id = TYPE_UNKNOWN, info = Unknown_Type{}})
	append(&reg.types, Type{id = TYPE_NEVER,   info = Never_Type{}})
	append(&reg.types, Type{id = TYPE_OBJECT,  info = Primitive_Type{.Object}})

	return reg
}

get_type :: proc(reg: ^Type_Registry, id: Type_ID) -> ^Type {
	idx := int(id)
	if idx < 0 || idx >= len(reg.types) {
		return &reg.types[0] // INVALID
	}
	return &reg.types[idx]
}

register_type :: proc(reg: ^Type_Registry, info: Type_Info) -> Type_ID {
	id := Type_ID(len(reg.types))
	append(&reg.types, Type{id = id, info = info})
	return id
}

// ==================== Compound Type Constructors ====================

make_union_type :: proc(reg: ^Type_Registry, members_in: []Type_ID) -> Type_ID {
	// Flatten nested unions, deduplicate, sort
	flat := make([dynamic]Type_ID, 0, len(members_in) * 2, reg.allocator)
	for m in members_in {
		if m == INVALID_TYPE || m == TYPE_NEVER { continue }
		t := get_type(reg, m)
		#partial switch info in t.info {
		case Union_Type:
			for inner in info.members {
				if inner != INVALID_TYPE && inner != TYPE_NEVER {
					// Dedup
					found := false
					for existing in flat {
						if existing == inner { found = true; break }
					}
					if !found { append(&flat, inner) }
				}
			}
		case:
			found := false
			for existing in flat {
				if existing == m { found = true; break }
			}
			if !found { append(&flat, m) }
		}
	}

	if len(flat) == 0 { return TYPE_NEVER }
	if len(flat) == 1 { return flat[0] }

	// Sort for canonical form
	slice.sort_by(flat[:], proc(a, b: Type_ID) -> bool {
		return u32(a) < u32(b)
	})

	// Hash for cache
	h: u64 = 0
	for m in flat {
		h = h * 31 + u64(m)
	}

	if cached, ok := reg.union_cache[h]; ok {
		return cached
	}

	// Register
	members_slice := make([]Type_ID, len(flat), reg.allocator)
	copy(members_slice, flat[:])
	id := register_type(reg, Union_Type{members = members_slice})
	reg.union_cache[h] = id
	return id
}

make_list_type :: proc(reg: ^Type_Registry, element: Type_ID) -> Type_ID {
	if cached, ok := reg.list_cache[element]; ok {
		return cached
	}
	id := register_type(reg, List_Type{element = element})
	reg.list_cache[element] = id
	return id
}

make_dict_type :: proc(reg: ^Type_Registry, key: Type_ID, value: Type_ID) -> Type_ID {
	cache_key := [2]Type_ID{key, value}
	if cached, ok := reg.dict_cache[cache_key]; ok {
		return cached
	}
	id := register_type(reg, Dict_Type{key = key, value = value})
	reg.dict_cache[cache_key] = id
	return id
}

make_set_type :: proc(reg: ^Type_Registry, element: Type_ID) -> Type_ID {
	if cached, ok := reg.set_cache[element]; ok {
		return cached
	}
	id := register_type(reg, Set_Type{element = element})
	reg.set_cache[element] = id
	return id
}

make_tuple_type :: proc(reg: ^Type_Registry, elements: []Type_ID, is_variadic: bool) -> Type_ID {
	elems := make([]Type_ID, len(elements), reg.allocator)
	copy(elems, elements)
	return register_type(reg, Tuple_Type{elements = elems, is_variadic = is_variadic})
}

make_callable_type :: proc(reg: ^Type_Registry, params: []Param_Type, return_type: Type_ID) -> Type_ID {
	ps := make([]Param_Type, len(params), reg.allocator)
	copy(ps, params)
	return register_type(reg, Callable_Type{params = ps, return_type = return_type})
}

make_instance_type :: proc(reg: ^Type_Registry, class_type: Type_ID) -> Type_ID {
	return register_type(reg, Instance_Type{class_type = class_type})
}

// ==================== Subtype Checking ====================

is_assignable :: proc(reg: ^Type_Registry, source: Type_ID, target: Type_ID) -> bool {
	if source == target { return true }
	if target == TYPE_ANY || target == TYPE_UNKNOWN { return true }
	if source == TYPE_ANY || source == TYPE_UNKNOWN { return true }
	if source == TYPE_NEVER { return true } // bottom type
	if target == TYPE_OBJECT { return true } // top type

	// bool <: int
	if source == TYPE_BOOL && target == TYPE_INT { return true }
	// int <: float
	if source == TYPE_INT && target == TYPE_FLOAT { return true }
	// bool <: float (transitive)
	if source == TYPE_BOOL && target == TYPE_FLOAT { return true }

	src_type := get_type(reg, source)
	tgt_type := get_type(reg, target)

	// Literal <: base type
	#partial switch _ in src_type.info {
	case Literal_Int_Type:
		if target == TYPE_INT || target == TYPE_FLOAT { return true }
	case Literal_Str_Type:
		if target == TYPE_STR { return true }
	case Literal_Bool_Type:
		if target == TYPE_BOOL || target == TYPE_INT || target == TYPE_FLOAT { return true }
	}

	// Source union: all members must be assignable to target
	#partial switch src in src_type.info {
	case Union_Type:
		for m in src.members {
			if !is_assignable(reg, m, target) { return false }
		}
		return true
	}

	// Target union: source must be assignable to at least one member
	#partial switch tgt in tgt_type.info {
	case Union_Type:
		for m in tgt.members {
			if is_assignable(reg, source, m) { return true }
		}
		return false
	}

	// List invariance: list[S] <: list[T] only if S == T
	#partial switch src in src_type.info {
	case List_Type:
		#partial switch tgt in tgt_type.info {
		case List_Type:
			return src.element == tgt.element
		}
	}

	// Dict invariance
	#partial switch src in src_type.info {
	case Dict_Type:
		#partial switch tgt in tgt_type.info {
		case Dict_Type:
			return src.key == tgt.key && src.value == tgt.value
		}
	}

	// Set invariance
	#partial switch src in src_type.info {
	case Set_Type:
		#partial switch tgt in tgt_type.info {
		case Set_Type:
			return src.element == tgt.element
		}
	}

	// Tuple element-wise comparison
	#partial switch src in src_type.info {
	case Tuple_Type:
		#partial switch tgt in tgt_type.info {
		case Tuple_Type:
			if len(src.elements) != len(tgt.elements) { return false }
			for e, i in src.elements {
				if !is_assignable(reg, e, tgt.elements[i]) { return false }
			}
			return true
		}
	}

	// Instance subtyping via inheritance
	#partial switch src in src_type.info {
	case Instance_Type:
		#partial switch tgt in tgt_type.info {
		case Instance_Type:
			return is_class_subtype(reg, src.class_type, tgt.class_type)
		}
	}

	return false
}

is_class_subtype :: proc(reg: ^Type_Registry, sub_class: Type_ID, super_class: Type_ID) -> bool {
	if sub_class == super_class { return true }
	t := get_type(reg, sub_class)
	#partial switch cls in t.info {
	case Class_Type:
		for base in cls.bases {
			if is_class_subtype(reg, base, super_class) { return true }
		}
	}
	return false
}

// ==================== Type Utilities ====================

is_numeric :: proc(reg: ^Type_Registry, t: Type_ID) -> bool {
	return t == TYPE_INT || t == TYPE_FLOAT || t == TYPE_BOOL || t == TYPE_COMPLEX
}

is_list_type :: proc(reg: ^Type_Registry, t: Type_ID) -> bool {
	typ := get_type(reg, t)
	_, ok := typ.info.(List_Type)
	return ok
}

is_set_type :: proc(reg: ^Type_Registry, t: Type_ID) -> bool {
	typ := get_type(reg, t)
	_, ok := typ.info.(Set_Type)
	return ok
}

is_dict_type :: proc(reg: ^Type_Registry, t: Type_ID) -> bool {
	typ := get_type(reg, t)
	_, ok := typ.info.(Dict_Type)
	return ok
}

get_list_element :: proc(reg: ^Type_Registry, t: Type_ID) -> Type_ID {
	typ := get_type(reg, t)
	#partial switch info in typ.info {
	case List_Type: return info.element
	}
	return TYPE_UNKNOWN
}

remove_none :: proc(reg: ^Type_Registry, t: Type_ID) -> Type_ID {
	if t == TYPE_NONE { return TYPE_NEVER }
	typ := get_type(reg, t)
	#partial switch info in typ.info {
	case Union_Type:
		filtered := make([dynamic]Type_ID, 0, len(info.members), reg.allocator)
		for m in info.members {
			if m != TYPE_NONE { append(&filtered, m) }
		}
		if len(filtered) == 0 { return TYPE_NEVER }
		if len(filtered) == 1 { return filtered[0] }
		return make_union_type(reg, filtered[:])
	}
	return t
}

subtract_type :: proc(reg: ^Type_Registry, base: Type_ID, remove: Type_ID) -> Type_ID {
	if base == remove { return TYPE_NEVER }
	typ := get_type(reg, base)
	#partial switch info in typ.info {
	case Union_Type:
		filtered := make([dynamic]Type_ID, 0, len(info.members), reg.allocator)
		for m in info.members {
			if !is_assignable(reg, m, remove) { append(&filtered, m) }
		}
		if len(filtered) == 0 { return TYPE_NEVER }
		if len(filtered) == 1 { return filtered[0] }
		return make_union_type(reg, filtered[:])
	}
	return base
}

// ==================== Type Display ====================

type_to_string :: proc(reg: ^Type_Registry, id: Type_ID) -> string {
	if id == INVALID_TYPE { return "<invalid>" }

	t := get_type(reg, id)
	#partial switch info in t.info {
	case Primitive_Type:
		switch info.kind {
		case .Int:       return "int"
		case .Float:     return "float"
		case .Str:       return "str"
		case .Bytes:     return "bytes"
		case .Bool:      return "bool"
		case .None_Type: return "None"
		case .Complex:   return "complex"
		case .Object:    return "object"
		}
	case Any_Type:     return "Any"
	case Unknown_Type: return "Unknown"
	case Never_Type:   return "Never"
	case Union_Type:
		buf := make([dynamic]u8, 0, 64, reg.allocator)
		for m, i in info.members {
			if i > 0 { append(&buf, ' '); append(&buf, '|'); append(&buf, ' ') }
			ms := type_to_string(reg, m)
			for c in ms { append(&buf, u8(c)) }
		}
		return string(buf[:])
	case Callable_Type:
		return fmt.aprintf("Callable[..., %s]", type_to_string(reg, info.return_type), allocator = reg.allocator)
	case List_Type:
		return fmt.aprintf("list[%s]", type_to_string(reg, info.element), allocator = reg.allocator)
	case Dict_Type:
		return fmt.aprintf("dict[%s, %s]", type_to_string(reg, info.key), type_to_string(reg, info.value), allocator = reg.allocator)
	case Set_Type:
		return fmt.aprintf("set[%s]", type_to_string(reg, info.element), allocator = reg.allocator)
	case Tuple_Type:
		buf := make([dynamic]u8, 0, 64, reg.allocator)
		for c in "tuple[" { append(&buf, u8(c)) }
		for e, i in info.elements {
			if i > 0 { append(&buf, ','); append(&buf, ' ') }
			es := type_to_string(reg, e)
			for c in es { append(&buf, u8(c)) }
		}
		if info.is_variadic { for c in ", ..." { append(&buf, u8(c)) } }
		append(&buf, ']')
		return string(buf[:])
	case Class_Type:
		return fmt.aprintf("type[%s]", info.name, allocator = reg.allocator)
	case Instance_Type:
		cls := get_type(reg, info.class_type)
		#partial switch ci in cls.info {
		case Class_Type: return ci.name
		}
		return "<instance>"
	case Literal_Int_Type:
		return fmt.aprintf("Literal[%d]", info.value, allocator = reg.allocator)
	case Literal_Str_Type:
		return fmt.aprintf("Literal[\"%s\"]", info.value, allocator = reg.allocator)
	case Literal_Bool_Type:
		if info.value { return "Literal[True]" }
		return "Literal[False]"
	case Module_Type:
		return "<module>"
	}
	return "<unknown>"
}
