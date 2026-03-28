package modules

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

import checker "mimir:checker"

// Disk-based export cache for parsed packages and stdlib stubs.
// After first parse, writes a summary .pyi to ~/.mimir/stubs/cache/<name>-<key>.pyi.
// Subsequent runs parse the small cached .pyi instead of the full package + DFS.

// Check if a cached stub exists for a module.
// Returns the file path if found.
read_stub_cache :: proc(
	module_name: string,
	cache_dir: string,
	cache_key: string,
	allocator: mem.Allocator,
) -> (file_path: string, found: bool) {
	if len(cache_dir) == 0 { return "", false }

	path := _cache_path(module_name, cache_dir, cache_key, allocator)
	if os.is_file(path) {
		return path, true
	}
	return "", false
}

// Write a summary .pyi stub for a parsed module's exports.
// Generates minimal type annotations from the export map.
write_stub_cache :: proc(
	module_name: string,
	exports: ^Module_Exports,
	registry: ^checker.Type_Registry,
	cache_dir: string,
	cache_key: string,
	allocator: mem.Allocator,
) -> bool {
	if len(cache_dir) == 0 { return false }
	if exports == nil || len(exports.types) == 0 { return false }

	// Ensure cache directory exists
	os.make_directory_all(cache_dir)

	buf := make([dynamic]u8, 0, 2048, allocator)
	_append_str(&buf, "# Auto-generated stub cache by mimir\n")
	_append_str(&buf, "# Do not edit — regenerated from package source\n\n")

	// Track if we need typing imports
	needs_any := false
	needs_callable := false
	needs_union := false

	// First pass: check what imports we need
	for _, type_id in exports.types {
		_scan_type_imports(registry, type_id, &needs_any, &needs_callable, &needs_union)
	}

	// Write typing imports
	if needs_any || needs_callable || needs_union {
		_append_str(&buf, "from typing import ")
		first := true
		if needs_any { _append_str(&buf, "Any"); first = false }
		if needs_callable {
			if !first { _append_str(&buf, ", ") }
			_append_str(&buf, "Callable")
			first = false
		}
		if needs_union {
			if !first { _append_str(&buf, ", ") }
			_append_str(&buf, "Union")
		}
		_append_str(&buf, "\n\n")
	}

	// Write exports
	for name, type_id in exports.types {
		t := checker.get_type(registry, type_id)

		#partial switch info in t.info {
		case checker.Callable_Type:
			// Render as function def
			_append_str(&buf, "def ")
			_append_str(&buf, name)
			_append_str(&buf, "(")
			for p, pi in info.params {
				if pi > 0 { _append_str(&buf, ", ") }
				_append_str(&buf, p.name if len(p.name) > 0 else fmt.tprintf("arg%d", pi))
				ts := _type_str(registry, p.type_id, allocator)
				if len(ts) > 0 {
					_append_str(&buf, ": ")
					_append_str(&buf, ts)
				}
				if p.has_default {
					_append_str(&buf, " = ...")
				}
			}
			_append_str(&buf, ")")
			ret := _type_str(registry, info.return_type, allocator)
			if len(ret) > 0 {
				_append_str(&buf, " -> ")
				_append_str(&buf, ret)
			}
			_append_str(&buf, ": ...\n")

		case checker.Class_Type:
			// Render as class with attrs
			_append_str(&buf, "class ")
			_append_str(&buf, name)
			_append_str(&buf, ":\n")
			has_content := false
			for attr_name, attr_id in info.attrs {
				at := checker.get_type(registry, attr_id)
				#partial switch ai in at.info {
				case checker.Callable_Type:
					_append_str(&buf, "    def ")
					_append_str(&buf, attr_name)
					_append_str(&buf, "(self")
					for p, pi in ai.params {
						_append_str(&buf, ", ")
						_append_str(&buf, p.name if len(p.name) > 0 else fmt.tprintf("arg%d", pi))
						ts := _type_str(registry, p.type_id, allocator)
						if len(ts) > 0 {
							_append_str(&buf, ": ")
							_append_str(&buf, ts)
						}
						if p.has_default {
							_append_str(&buf, " = ...")
						}
					}
					_append_str(&buf, ")")
					ret := _type_str(registry, ai.return_type, allocator)
					if len(ret) > 0 {
						_append_str(&buf, " -> ")
						_append_str(&buf, ret)
					}
					_append_str(&buf, ": ...\n")
					has_content = true
				case:
					ts := _type_str(registry, attr_id, allocator)
					if len(ts) > 0 {
						_append_str(&buf, "    ")
						_append_str(&buf, attr_name)
						_append_str(&buf, ": ")
						_append_str(&buf, ts)
						_append_str(&buf, "\n")
						has_content = true
					}
				}
			}
			if !has_content {
				_append_str(&buf, "    ...\n")
			}
			_append_str(&buf, "\n")

		case:
			// Variable with type annotation
			ts := _type_str(registry, type_id, allocator)
			if len(ts) > 0 {
				_append_str(&buf, name)
				_append_str(&buf, ": ")
				_append_str(&buf, ts)
				_append_str(&buf, "\n")
			}
		}
	}

	path := _cache_path(module_name, cache_dir, cache_key, allocator)
	write_err := os.write_entire_file(path, buf[:])
	return write_err == nil
}

// ==================== Helpers ====================

@(private = "file")
_cache_path :: proc(module_name: string, cache_dir: string, cache_key: string, allocator: mem.Allocator) -> string {
	safe_name := module_name
	// Replace dots with underscores for filename safety
	buf := make([dynamic]u8, 0, len(module_name), allocator)
	for c in module_name {
		if c == '.' { append(&buf, '_') }
		else { append(&buf, u8(c)) }
	}
	safe_name = string(buf[:])

	if len(cache_key) > 0 {
		return strings.concatenate({cache_dir, "/", safe_name, "-", cache_key, ".pyi"}, allocator)
	}
	return strings.concatenate({cache_dir, "/", safe_name, ".pyi"}, allocator)
}

@(private = "file")
_type_str :: proc(registry: ^checker.Type_Registry, id: checker.Type_ID, allocator: mem.Allocator) -> string {
	if id == checker.INVALID_TYPE || id == checker.TYPE_UNKNOWN { return "" }

	t := checker.get_type(registry, id)
	#partial switch info in t.info {
	case checker.Primitive_Type:
		switch info.kind {
		case .Int: return "int"
		case .Float: return "float"
		case .Str: return "str"
		case .Bytes: return "bytes"
		case .Bool: return "bool"
		case .None_Type: return "None"
		case .Complex: return "complex"
		case .Object: return "object"
		}
	case checker.Any_Type: return "Any"
	case checker.Never_Type: return "Never"
	case checker.Instance_Type:
		ct := checker.get_type(registry, info.class_type)
		#partial switch ci in ct.info {
		case checker.Class_Type: return ci.name
		}
		return ""
	case checker.Class_Type: return fmt.aprintf("type[%s]", info.name, allocator = allocator)
	case checker.Module_Type: return ""
	case checker.Union_Type:
		b := make([dynamic]u8, 0, 64, allocator)
		for m, i in info.members {
			if i > 0 { _append_str(&b, " | ") }
			ms := _type_str(registry, m, allocator)
			if len(ms) > 0 { _append_str(&b, ms) }
			else { _append_str(&b, "Any") }
		}
		return string(b[:])
	case checker.List_Type:
		elem := _type_str(registry, info.element, allocator)
		if len(elem) > 0 { return fmt.aprintf("list[%s]", elem, allocator = allocator) }
		return "list"
	case checker.Dict_Type:
		k := _type_str(registry, info.key, allocator)
		v := _type_str(registry, info.value, allocator)
		if len(k) > 0 && len(v) > 0 { return fmt.aprintf("dict[%s, %s]", k, v, allocator = allocator) }
		return "dict"
	case checker.Tuple_Type:
		b := make([dynamic]u8, 0, 64, allocator)
		_append_str(&b, "tuple[")
		for m, i in info.elements {
			if i > 0 { _append_str(&b, ", ") }
			ms := _type_str(registry, m, allocator)
			if len(ms) > 0 { _append_str(&b, ms) }
			else { _append_str(&b, "Any") }
		}
		_append_str(&b, "]")
		return string(b[:])
	case checker.Set_Type:
		elem := _type_str(registry, info.element, allocator)
		if len(elem) > 0 { return fmt.aprintf("set[%s]", elem, allocator = allocator) }
		return "set"
	case checker.Callable_Type:
		return "Callable"
	}
	return ""
}

@(private = "file")
_scan_type_imports :: proc(registry: ^checker.Type_Registry, id: checker.Type_ID, needs_any, needs_callable, needs_union: ^bool) {
	if id == checker.INVALID_TYPE || id == checker.TYPE_UNKNOWN { return }
	t := checker.get_type(registry, id)
	#partial switch info in t.info {
	case checker.Any_Type: needs_any^ = true
	case checker.Callable_Type: needs_callable^ = true
	case checker.Union_Type: needs_union^ = true
	}
}

@(private = "file")
_append_str :: proc(buf: ^[dynamic]u8, s: string) {
	for i := 0; i < len(s); i += 1 {
		append(buf, s[i])
	}
}
