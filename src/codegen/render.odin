package codegen

import "core:fmt"
import "core:mem"

import checker "mimir:checker"

// Tracks which typing imports the generated output needs
Needed_Imports :: struct {
	any_type: bool,
	callable: bool,
	never:    bool,
}

// Renders a Type_ID as valid Python type annotation syntax.
// Returns "" for TYPE_UNKNOWN / unrenderable types (caller should omit annotation).
type_to_python :: proc(reg: ^checker.Type_Registry, id: checker.Type_ID, imports: ^Needed_Imports, allocator: mem.Allocator) -> string {
	if id == checker.INVALID_TYPE || id == checker.TYPE_UNKNOWN { return "" }

	t := checker.get_type(reg, id)
	#partial switch info in t.info {
	case checker.Primitive_Type:
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
	case checker.Any_Type:
		if imports != nil { imports.any_type = true }
		return "Any"
	case checker.Unknown_Type:
		return ""
	case checker.Never_Type:
		if imports != nil { imports.never = true }
		return "Never"
	case checker.Union_Type:
		buf := make([dynamic]u8, 0, 64, allocator)
		for m, i in info.members {
			if i > 0 { append(&buf, ' '); append(&buf, '|'); append(&buf, ' ') }
			ms := type_to_python(reg, m, imports, allocator)
			if ms == "" { ms = "Any"; if imports != nil { imports.any_type = true } }
			for c in ms { append(&buf, u8(c)) }
		}
		return string(buf[:])
	case checker.Callable_Type:
		if imports != nil { imports.callable = true }
		buf := make([dynamic]u8, 0, 64, allocator)
		for c in "Callable[[" { append(&buf, u8(c)) }
		for p, i in info.params {
			if i > 0 { append(&buf, ','); append(&buf, ' ') }
			ps := type_to_python(reg, p.type_id, imports, allocator)
			if ps == "" { ps = "Any"; if imports != nil { imports.any_type = true } }
			for c in ps { append(&buf, u8(c)) }
		}
		for c in "], " { append(&buf, u8(c)) }
		rs := type_to_python(reg, info.return_type, imports, allocator)
		if rs == "" { rs = "Any"; if imports != nil { imports.any_type = true } }
		for c in rs { append(&buf, u8(c)) }
		append(&buf, ']')
		return string(buf[:])
	case checker.List_Type:
		es := type_to_python(reg, info.element, imports, allocator)
		if es == "" { es = "Any"; if imports != nil { imports.any_type = true } }
		return fmt.aprintf("list[%s]", es, allocator = allocator)
	case checker.Dict_Type:
		ks := type_to_python(reg, info.key, imports, allocator)
		vs := type_to_python(reg, info.value, imports, allocator)
		if ks == "" { ks = "Any"; if imports != nil { imports.any_type = true } }
		if vs == "" { vs = "Any"; if imports != nil { imports.any_type = true } }
		return fmt.aprintf("dict[%s, %s]", ks, vs, allocator = allocator)
	case checker.Set_Type:
		es := type_to_python(reg, info.element, imports, allocator)
		if es == "" { es = "Any"; if imports != nil { imports.any_type = true } }
		return fmt.aprintf("set[%s]", es, allocator = allocator)
	case checker.Tuple_Type:
		buf := make([dynamic]u8, 0, 64, allocator)
		for c in "tuple[" { append(&buf, u8(c)) }
		for e, i in info.elements {
			if i > 0 { append(&buf, ','); append(&buf, ' ') }
			es := type_to_python(reg, e, imports, allocator)
			if es == "" { es = "Any"; if imports != nil { imports.any_type = true } }
			for c in es { append(&buf, u8(c)) }
		}
		if info.is_variadic { for c in ", ..." { append(&buf, u8(c)) } }
		append(&buf, ']')
		return string(buf[:])
	case checker.Class_Type:
		return fmt.aprintf("type[%s]", info.name, allocator = allocator)
	case checker.Instance_Type:
		cls := checker.get_type(reg, info.class_type)
		#partial switch ci in cls.info {
		case checker.Class_Type: return ci.name
		}
		return "object"
	case checker.TypeVar_Type:
		return info.name
	case checker.TypedDict_Type:
		return info.name
	case checker.Protocol_Type:
		return info.name
	case checker.Literal_Int_Type:
		return "int"
	case checker.Literal_Str_Type:
		return "str"
	case checker.Literal_Bool_Type:
		return "bool"
	case checker.Module_Type:
		return ""
	}
	return ""
}

// Builds the `from typing import ...` line needed for generated output
format_typing_imports :: proc(imports: ^Needed_Imports, allocator: mem.Allocator) -> string {
	names := make([dynamic]string, 0, 4, allocator)
	if imports.any_type { append(&names, "Any") }
	if imports.callable { append(&names, "Callable") }
	if imports.never { append(&names, "Never") }

	if len(names) == 0 { return "" }

	buf := make([dynamic]u8, 0, 64, allocator)
	append_str(&buf, "from typing import ")
	for n, i in names {
		if i > 0 { append_str(&buf, ", ") }
		append_str(&buf, n)
	}
	append(&buf, '\n')
	return string(buf[:])
}

// Shared error type for all codegen operations
Generate_Error :: union {
	Error_Data,
}

Error_Data :: struct {
	msg: string,
}

// Buffer helpers
append_str :: proc(buf: ^[dynamic]u8, s: string) {
	for c in s { append(buf, u8(c)) }
}

append_indent :: proc(buf: ^[dynamic]u8, level: int) {
	for _ in 0..<level {
		append(buf, ' ')
		append(buf, ' ')
		append(buf, ' ')
		append(buf, ' ')
	}
}
