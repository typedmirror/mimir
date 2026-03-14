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
	TypeVar_Type,
	TypedDict_Type,
	Protocol_Type,
	Tensor_Type,
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
	is_variadic: bool, // *args or **kwargs parameter
}

List_Type :: struct { element: Type_ID }
Dict_Type :: struct { key: Type_ID, value: Type_ID }
Set_Type  :: struct { element: Type_ID }

Tuple_Type :: struct {
	elements:    []Type_ID,
	is_variadic: bool,
}

Class_Type :: struct {
	name:        string,
	symbol_id:   binder.Symbol_ID,
	scope_id:    binder.Scope_ID,
	bases:       []Type_ID,
	attrs:       map[string]Type_ID,
	type_params: []Type_ID,
}

Instance_Type :: struct {
	class_type: Type_ID,
}

Literal_Int_Type  :: struct { value: i64 }
Literal_Str_Type  :: struct { value: string }
Literal_Bool_Type :: struct { value: bool }

Module_Type :: struct {
	scope_id: binder.Scope_ID,
	name:     string,
	exports:  map[string]Type_ID,
}

TypeVar_Type :: struct {
	name:        string,
	bound:       Type_ID,
	constraints: []Type_ID,
}

TypedDict_Type :: struct {
	name:   string,
	fields: map[string]Type_ID,
	total:  bool,
}

Protocol_Type :: struct {
	name:    string,
	methods: map[string]Type_ID,
	attrs:   map[string]Type_ID,
}

Tensor_Type :: struct {
	element_type: Type_ID,     // float32, float16, int32, etc.
	shape:        []int,       // concrete dimensions (-1 = symbolic/unknown)
	ndim:         int,         // number of dimensions (len(shape), cached)
}

// ==================== Type Environment ====================

Type_Env :: struct {
	types: map[binder.Symbol_ID]Type_ID,
}

// ==================== Type Registry ====================

Spec_Cache_Entry :: struct {
	result:        Type_ID,
	class_type_id: Type_ID,
	type_args:     []Type_ID,
}

Type_Registry :: struct {
	types:       [dynamic]Type,
	union_cache: map[u64]Type_ID,
	list_cache:  map[Type_ID]Type_ID,
	dict_cache:  map[[2]Type_ID]Type_ID,
	set_cache:   map[Type_ID]Type_ID,
	class_types:    map[binder.Symbol_ID]Type_ID,
	instance_cache: map[Type_ID]Type_ID,
	spec_cache:     map[u64]Spec_Cache_Entry,
	tensor_cache:   map[u64]Type_ID,
	overload_sigs:  map[binder.Symbol_ID][dynamic]Type_ID,
	allocator:      mem.Allocator,
}

init_registry :: proc(allocator: mem.Allocator) -> Type_Registry {
	reg: Type_Registry
	reg.allocator = allocator
	reg.types = make([dynamic]Type, 0, 256, allocator)
	reg.union_cache = make(map[u64]Type_ID, 64, allocator)
	reg.list_cache = make(map[Type_ID]Type_ID, 16, allocator)
	reg.dict_cache = make(map[[2]Type_ID]Type_ID, 16, allocator)
	reg.set_cache = make(map[Type_ID]Type_ID, 16, allocator)
	reg.class_types = make(map[binder.Symbol_ID]Type_ID, 16, allocator)
	reg.instance_cache = make(map[Type_ID]Type_ID, 16, allocator)
	reg.spec_cache = make(map[u64]Spec_Cache_Entry, 8, allocator)
	reg.tensor_cache = make(map[u64]Type_ID, 8, allocator)
	reg.overload_sigs = make(map[binder.Symbol_ID][dynamic]Type_ID, 8, allocator)

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
		// Verify cache hit — collision detection
		ct := get_type(reg, cached)
		if ut, is_union := ct.info.(Union_Type); is_union && len(ut.members) == len(flat) {
			match := true
			for i := 0; i < len(flat); i += 1 {
				if flat[i] != ut.members[i] { match = false; break }
			}
			if match { return cached }
		}
		// Hash collision — fall through to register new type
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
	if cached, ok := reg.instance_cache[class_type]; ok {
		return cached
	}
	id := register_type(reg, Instance_Type{class_type = class_type})
	reg.instance_cache[class_type] = id
	return id
}

make_typeddict_type :: proc(reg: ^Type_Registry, name: string, fields: map[string]Type_ID, total: bool) -> Type_ID {
	return register_type(reg, TypedDict_Type{name = name, fields = fields, total = total})
}

make_tensor_type :: proc(reg: ^Type_Registry, element_type: Type_ID, shape: []int) -> Type_ID {
	// Hash: element_type + shape dims
	h: u64 = u64(element_type) * 31
	for d in shape {
		h = h * 31 + u64(u32(d))
	}
	if cached, ok := reg.tensor_cache[h]; ok {
		ct := get_type(reg, cached)
		if tt, is_tensor := ct.info.(Tensor_Type); is_tensor {
			if tt.element_type == element_type && len(tt.shape) == len(shape) {
				match := true
				for i := 0; i < len(shape); i += 1 {
					if tt.shape[i] != shape[i] { match = false; break }
				}
				if match { return cached }
			}
		}
	}
	s := make([]int, len(shape), reg.allocator)
	copy(s, shape)
	id := register_type(reg, Tensor_Type{element_type = element_type, shape = s, ndim = len(shape)})
	reg.tensor_cache[h] = id
	return id
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

	// TypeVar types are permissive (resolved via substitution at call sites)
	if _, src_is_tv := src_type.info.(TypeVar_Type); src_is_tv { return true }
	if _, tgt_is_tv := tgt_type.info.(TypeVar_Type); tgt_is_tv { return true }

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

	// List invariance: list[S] <: list[T] only if S and T are structurally equal
	#partial switch src in src_type.info {
	case List_Type:
		#partial switch tgt in tgt_type.info {
		case List_Type:
			return is_assignable(reg, src.element, tgt.element) && is_assignable(reg, tgt.element, src.element)
		}
	}

	// Dict invariance
	#partial switch src in src_type.info {
	case Dict_Type:
		#partial switch tgt in tgt_type.info {
		case Dict_Type:
			return (is_assignable(reg, src.key, tgt.key) && is_assignable(reg, tgt.key, src.key)) &&
			       (is_assignable(reg, src.value, tgt.value) && is_assignable(reg, tgt.value, src.value))
		}
	}

	// Set invariance
	#partial switch src in src_type.info {
	case Set_Type:
		#partial switch tgt in tgt_type.info {
		case Set_Type:
			return is_assignable(reg, src.element, tgt.element) && is_assignable(reg, tgt.element, src.element)
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

	// Callable structural comparison (params are contravariant, return is covariant)
	#partial switch src in src_type.info {
	case Callable_Type:
		#partial switch tgt in tgt_type.info {
		case Callable_Type:
			if len(src.params) != len(tgt.params) { return false }
			for i in 0..<len(src.params) {
				// Contravariant: target param must be assignable TO source param
				if !is_assignable(reg, tgt.params[i].type_id, src.params[i].type_id) { return false }
			}
			return is_assignable(reg, src.return_type, tgt.return_type)
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

	// TypedDict subtyping: source TypedDict must have all target TypedDict fields
	#partial switch src in src_type.info {
	case TypedDict_Type:
		#partial switch tgt in tgt_type.info {
		case TypedDict_Type:
			for name, tgt_field_type in tgt.fields {
				src_field_type, ok := src.fields[name]
				if !ok { return false }
				if !is_assignable(reg, src_field_type, tgt_field_type) { return false }
			}
			return true
		case Dict_Type:
			// TypedDict is a dict subtype
			if tgt.key != TYPE_STR && tgt.key != TYPE_ANY && tgt.key != TYPE_UNKNOWN { return false }
			return true
		}
	}

	// Protocol structural subtyping: Instance must have matching methods/attrs with compatible types
	#partial switch tgt in tgt_type.info {
	case Protocol_Type:
		#partial switch src in src_type.info {
		case Instance_Type:
			cls := get_type(reg, src.class_type)
			#partial switch cls_info in cls.info {
			case Class_Type:
				for method_name, method_type in tgt.methods {
					cls_attr, ok := cls_info.attrs[method_name]
					if !ok { return false }
					// Check type compatibility if both types are known
					if method_type != TYPE_UNKNOWN && cls_attr != TYPE_UNKNOWN {
						if !is_assignable(reg, cls_attr, method_type) { return false }
					}
				}
				for attr_name, attr_type in tgt.attrs {
					cls_attr, ok := cls_info.attrs[attr_name]
					if !ok { return false }
					if attr_type != TYPE_UNKNOWN && cls_attr != TYPE_UNKNOWN {
						if !is_assignable(reg, cls_attr, attr_type) { return false }
					}
				}
				return true
			}
		}
		return false
	}

	// Tensor assignability: exact match or shape-erased
	#partial switch src in src_type.info {
	case Tensor_Type:
		#partial switch tgt in tgt_type.info {
		case Tensor_Type:
			if src.element_type != tgt.element_type { return false }
			// Shape-erased target (ndim == 0) accepts any shape
			if tgt.ndim == 0 { return true }
			if src.ndim != tgt.ndim { return false }
			for i := 0; i < src.ndim; i += 1 {
				// -1 = symbolic/unknown matches anything
				if src.shape[i] == -1 || tgt.shape[i] == -1 { continue }
				if src.shape[i] != tgt.shape[i] { return false }
			}
			return true
		}
	}

	return false
}

is_class_subtype :: proc(reg: ^Type_Registry, sub_class: Type_ID, super_class: Type_ID, depth: int = 0) -> bool {
	if sub_class == super_class { return true }
	if depth > 32 { return false }  // cycle guard
	t := get_type(reg, sub_class)
	#partial switch cls in t.info {
	case Class_Type:
		for base in cls.bases {
			if is_class_subtype(reg, base, super_class, depth + 1) { return true }
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
		buf := make([dynamic]u8, 0, 64, reg.allocator)
		for c in "Callable[[" { append(&buf, u8(c)) }
		for p, i in info.params {
			if i > 0 { append(&buf, ','); append(&buf, ' ') }
			ps := type_to_string(reg, p.type_id)
			for c in ps { append(&buf, u8(c)) }
		}
		for c in "], " { append(&buf, u8(c)) }
		rs := type_to_string(reg, info.return_type)
		for c in rs { append(&buf, u8(c)) }
		append(&buf, ']')
		return string(buf[:])
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
		if len(info.name) > 0 {
			return fmt.aprintf("module '%s'", info.name, allocator = reg.allocator)
		}
		return "<module>"
	case TypeVar_Type:
		return info.name
	case TypedDict_Type:
		return fmt.aprintf("TypedDict('%s')", info.name, allocator = reg.allocator)
	case Protocol_Type:
		return fmt.aprintf("Protocol('%s')", info.name, allocator = reg.allocator)
	case Tensor_Type:
		elem_str := type_to_string(reg, info.element_type)
		if info.ndim == 0 {
			return fmt.aprintf("Tensor[%s]", elem_str, allocator = reg.allocator)
		}
		buf := make([dynamic]u8, 0, 64, reg.allocator)
		for c in "Tensor[" { append(&buf, u8(c)) }
		for c in elem_str { append(&buf, u8(c)) }
		for i := 0; i < info.ndim; i += 1 {
			for c in ", " { append(&buf, u8(c)) }
			dim_str := fmt.tprintf("%d", info.shape[i])
			for c in dim_str { append(&buf, u8(c)) }
		}
		append(&buf, ']')
		return string(buf[:])
	}
	return "<unknown>"
}

// ==================== TypeVar Utilities ====================

is_typevar :: proc(reg: ^Type_Registry, t: Type_ID) -> bool {
	typ := get_type(reg, t)
	_, ok := typ.info.(TypeVar_Type)
	return ok
}

contains_typevar :: proc(reg: ^Type_Registry, t: Type_ID) -> bool {
	typ := get_type(reg, t)
	#partial switch info in typ.info {
	case TypeVar_Type: return true
	case List_Type:    return contains_typevar(reg, info.element)
	case Dict_Type:    return contains_typevar(reg, info.key) || contains_typevar(reg, info.value)
	case Set_Type:     return contains_typevar(reg, info.element)
	case Tuple_Type:
		for e in info.elements {
			if contains_typevar(reg, e) { return true }
		}
	case Union_Type:
		for m in info.members {
			if contains_typevar(reg, m) { return true }
		}
	case Callable_Type:
		for p in info.params {
			if contains_typevar(reg, p.type_id) { return true }
		}
		return contains_typevar(reg, info.return_type)
	case TypedDict_Type:
		for _, ft in info.fields {
			if contains_typevar(reg, ft) { return true }
		}
	case Protocol_Type:
		for _, mt in info.methods {
			if contains_typevar(reg, mt) { return true }
		}
		for _, at in info.attrs {
			if contains_typevar(reg, at) { return true }
		}
	}
	return false
}

callable_has_typevars :: proc(info: ^Callable_Type, reg: ^Type_Registry) -> bool {
	for p in info.params {
		if contains_typevar(reg, p.type_id) { return true }
	}
	return contains_typevar(reg, info.return_type)
}

// ==================== Type Matching (TypeVar Inference) ====================

// Match a pattern type against a concrete type, extracting TypeVar bindings
match_type :: proc(reg: ^Type_Registry, pattern: Type_ID, concrete: Type_ID, subs: ^map[Type_ID]Type_ID) -> bool {
	pt := get_type(reg, pattern)
	#partial switch _ in pt.info {
	case TypeVar_Type:
		if existing, ok := subs[pattern]; ok {
			return existing == concrete || is_assignable(reg, concrete, existing)
		}
		subs[pattern] = concrete
		return true
	}

	#partial switch p_info in pt.info {
	case List_Type:
		ct := get_type(reg, concrete)
		#partial switch c_info in ct.info {
		case List_Type:
			return match_type(reg, p_info.element, c_info.element, subs)
		}
		return false
	case Dict_Type:
		ct := get_type(reg, concrete)
		#partial switch c_info in ct.info {
		case Dict_Type:
			return match_type(reg, p_info.key, c_info.key, subs) &&
			       match_type(reg, p_info.value, c_info.value, subs)
		}
		return false
	case Set_Type:
		ct := get_type(reg, concrete)
		#partial switch c_info in ct.info {
		case Set_Type:
			return match_type(reg, p_info.element, c_info.element, subs)
		}
		return false
	case Tuple_Type:
		ct := get_type(reg, concrete)
		#partial switch c_info in ct.info {
		case Tuple_Type:
			if len(p_info.elements) != len(c_info.elements) { return false }
			for e, i in p_info.elements {
				if !match_type(reg, e, c_info.elements[i], subs) { return false }
			}
			return true
		}
		return false
	}

	return is_assignable(reg, concrete, pattern)
}

// ==================== Type Substitution ====================

// Apply substitution map to a type, replacing TypeVars with concrete types
substitute_type :: proc(reg: ^Type_Registry, type_id: Type_ID, subs: map[Type_ID]Type_ID) -> Type_ID {
	if sub, ok := subs[type_id]; ok {
		return sub
	}

	t := get_type(reg, type_id)
	#partial switch info in t.info {
	case TypeVar_Type:
		return TYPE_ANY // Unresolved TypeVar fallback
	case List_Type:
		new_elem := substitute_type(reg, info.element, subs)
		if new_elem == info.element { return type_id }
		return make_list_type(reg, new_elem)
	case Dict_Type:
		new_key := substitute_type(reg, info.key, subs)
		new_val := substitute_type(reg, info.value, subs)
		if new_key == info.key && new_val == info.value { return type_id }
		return make_dict_type(reg, new_key, new_val)
	case Set_Type:
		new_elem := substitute_type(reg, info.element, subs)
		if new_elem == info.element { return type_id }
		return make_set_type(reg, new_elem)
	case Tuple_Type:
		changed := false
		new_elems := make([]Type_ID, len(info.elements), reg.allocator)
		for e, i in info.elements {
			new_elems[i] = substitute_type(reg, e, subs)
			if new_elems[i] != e { changed = true }
		}
		if !changed { return type_id }
		return make_tuple_type(reg, new_elems, info.is_variadic)
	case Union_Type:
		new_members := make([]Type_ID, len(info.members), reg.allocator)
		changed := false
		for m, i in info.members {
			new_members[i] = substitute_type(reg, m, subs)
			if new_members[i] != m { changed = true }
		}
		if !changed { return type_id }
		return make_union_type(reg, new_members)
	case Callable_Type:
		changed := false
		new_params := make([]Param_Type, len(info.params), reg.allocator)
		for p, i in info.params {
			new_type := substitute_type(reg, p.type_id, subs)
			new_params[i] = Param_Type{name = p.name, type_id = new_type, has_default = p.has_default}
			if new_type != p.type_id { changed = true }
		}
		new_ret := substitute_type(reg, info.return_type, subs)
		if new_ret != info.return_type { changed = true }
		if !changed { return type_id }
		return make_callable_type(reg, new_params, new_ret)
	}

	return type_id
}

// ==================== Class Specialization ====================

specialize_class :: proc(reg: ^Type_Registry, class_type_id: Type_ID, type_args: []Type_ID) -> Type_ID {
	// Cache key: hash of class + args
	h: u64 = u64(class_type_id)
	for arg in type_args {
		h = h * 31 + u64(arg)
	}
	if entry, ok := reg.spec_cache[h]; ok {
		// Verify cache hit — check class and type_args match exactly
		if entry.class_type_id == class_type_id && len(entry.type_args) == len(type_args) {
			args_match := true
			for i := 0; i < len(type_args); i += 1 {
				if entry.type_args[i] != type_args[i] { args_match = false; break }
			}
			if args_match {
				return entry.result
			}
		}
		// Hash collision — fall through to create new specialization (overwrites cache)
	}

	ct := get_type(reg, class_type_id)
	cls, ok := ct.info.(Class_Type)
	if !ok { return make_instance_type(reg, class_type_id) }

	// Build substitution map: type_params[i] → type_args[i]
	subs := make(map[Type_ID]Type_ID, len(cls.type_params), reg.allocator)
	for i := 0; i < min(len(cls.type_params), len(type_args)); i += 1 {
		subs[cls.type_params[i]] = type_args[i]
	}

	// Substitute all attrs
	new_attrs := make(map[string]Type_ID, len(cls.attrs), reg.allocator)
	for name, attr_type in cls.attrs {
		new_attrs[name] = substitute_type(reg, attr_type, subs)
	}

	// Create specialized Class_Type with empty type_params
	spec_id := register_type(reg, Class_Type{
		name      = cls.name,
		symbol_id = cls.symbol_id,
		scope_id  = cls.scope_id,
		bases     = cls.bases,
		attrs     = new_attrs,
	})

	result := make_instance_type(reg, spec_id)
	// Cache with type_args for collision verification
	cached_args := make([]Type_ID, len(type_args), reg.allocator)
	copy(cached_args, type_args)
	reg.spec_cache[h] = Spec_Cache_Entry{
		result        = result,
		class_type_id = class_type_id,
		type_args     = cached_args,
	}
	return result
}
