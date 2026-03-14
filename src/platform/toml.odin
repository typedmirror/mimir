package platform

import "core:mem"
import "core:strconv"
import "core:strings"
import "core:fmt"

// TOML parser for mimir.toml and mimir.lock.
// Handles: [section] headers, key = value pairs, # comments, empty lines,
// strings, booleans, integers, floats, arrays.
// Does NOT handle: datetime, inline tables, dotted keys, multi-line basic strings,
// [[array_of_tables]] syntax.

// ==================== Value Types ====================

Toml_Value :: union {
	string,
	i64,
	f64,
	bool,
	[dynamic]Toml_Value,
}

Toml_Table :: struct {
	entries: map[string]Toml_Value,
	order:   [dynamic]string,
}

Toml_Document :: struct {
	tables:      map[string]Toml_Table,
	table_order: [dynamic]string,
	root:        Toml_Table,
}

// ==================== Parser ====================

toml_parse :: proc(source: string, allocator: mem.Allocator) -> (Toml_Document, Platform_Error) {
	doc := Toml_Document{
		tables      = make(map[string]Toml_Table, 8, allocator),
		table_order = make([dynamic]string, 0, 4, allocator),
		root = Toml_Table{
			entries = make(map[string]Toml_Value, 8, allocator),
			order   = make([dynamic]string, 0, 4, allocator),
		},
	}

	current_section := ""
	lines := strings.split(source, "\n", allocator)

	for line in lines {
		trimmed := strings.trim_space(line)

		if trimmed == "" || trimmed[0] == '#' {
			continue
		}

		// Section header: [name]
		if trimmed[0] == '[' {
			close := strings.index(trimmed, "]")
			if close == -1 {
				return {}, Platform_Error_Data{msg = "TOML: unclosed section header"}
			}
			current_section = strings.clone(trimmed[1:close], allocator)

			if !(current_section in doc.tables) {
				doc.tables[current_section] = Toml_Table{
					entries = make(map[string]Toml_Value, 8, allocator),
					order   = make([dynamic]string, 0, 8, allocator),
				}
				append(&doc.table_order, current_section)
			}
			continue
		}

		// Key = value pair
		eq := strings.index(trimmed, "=")
		if eq == -1 {
			continue
		}

		key := strings.trim_space(trimmed[:eq])
		raw_val := strings.trim_space(trimmed[eq + 1:])

		// Strip inline comments (outside of quoted strings)
		raw_val = _strip_inline_comment(raw_val)

		val := _parse_value(raw_val, allocator)
		key = strings.clone(key, allocator)

		if current_section == "" {
			doc.root.entries[key] = val
			append(&doc.root.order, key)
		} else {
			table := &doc.tables[current_section]
			table.entries[key] = val
			append(&table.order, key)
		}
	}

	return doc, nil
}

// ==================== Value Parsing ====================

_parse_value :: proc(raw: string, allocator: mem.Allocator) -> Toml_Value {
	s := strings.trim_space(raw)
	if len(s) == 0 { return Toml_Value(strings.clone("", allocator)) }

	// Booleans
	if s == "true"  { return Toml_Value(true) }
	if s == "false" { return Toml_Value(false) }

	// Quoted strings
	if len(s) >= 2 && ((s[0] == '"' && s[len(s) - 1] == '"') || (s[0] == '\'' && s[len(s) - 1] == '\'')) {
		inner := s[1:len(s) - 1]
		// Double-quoted strings process escape sequences; single-quoted are literal
		if s[0] == '"' {
			return Toml_Value(_process_escapes(inner, allocator))
		}
		return Toml_Value(strings.clone(inner, allocator))
	}

	// Arrays
	if s[0] == '[' {
		return _parse_array(s, allocator)
	}

	// Numbers — try integer first, then float
	if _looks_like_number(s) {
		if ival, iok := strconv.parse_i64(s); iok {
			return Toml_Value(ival)
		}
		if fval, fok := strconv.parse_f64(s); fok {
			return Toml_Value(fval)
		}
	}

	// Unquoted string (fallback)
	return Toml_Value(strings.clone(s, allocator))
}

_process_escapes :: proc(s: string, allocator: mem.Allocator) -> string {
	// Fast path: no backslashes means no escapes to process
	has_escape := false
	for c in s {
		if c == '\\' { has_escape = true; break }
	}
	if !has_escape { return strings.clone(s, allocator) }

	buf := strings.builder_make(0, len(s), allocator)
	i := 0
	for i < len(s) {
		if s[i] == '\\' && i + 1 < len(s) {
			switch s[i + 1] {
			case '\\': strings.write_byte(&buf, '\\')
			case '"':  strings.write_byte(&buf, '"')
			case 'n':  strings.write_byte(&buf, '\n')
			case 't':  strings.write_byte(&buf, '\t')
			case 'r':  strings.write_byte(&buf, '\r')
			case 'b':  strings.write_byte(&buf, '\b')
			case 'f':  strings.write_byte(&buf, '\f')
			case:
				// Unknown escape — preserve as-is
				strings.write_byte(&buf, '\\')
				strings.write_byte(&buf, s[i + 1])
			}
			i += 2
		} else {
			strings.write_byte(&buf, s[i])
			i += 1
		}
	}
	return strings.to_string(buf)
}

_looks_like_number :: proc(s: string) -> bool {
	if len(s) == 0 { return false }
	start := 0
	if s[0] == '-' || s[0] == '+' { start = 1 }
	if start >= len(s) { return false }
	return s[start] >= '0' && s[start] <= '9'
}

_parse_array :: proc(s: string, allocator: mem.Allocator) -> Toml_Value {
	// Strip outer brackets
	if len(s) < 2 || s[0] != '[' || s[len(s) - 1] != ']' {
		return Toml_Value(make([dynamic]Toml_Value, 0, 0, allocator))
	}
	inner := strings.trim_space(s[1:len(s) - 1])
	if len(inner) == 0 {
		return Toml_Value(make([dynamic]Toml_Value, 0, 0, allocator))
	}

	// Split on commas at depth 0
	arr := make([dynamic]Toml_Value, 0, 4, allocator)
	depth := 0
	start := 0

	for i := 0; i < len(inner); i += 1 {
		c := inner[i]
		if c == '[' { depth += 1 }
		else if c == ']' { depth -= 1 }
		else if c == ',' && depth == 0 {
			elem := strings.trim_space(inner[start:i])
			if len(elem) > 0 {
				append(&arr, _parse_value(elem, allocator))
			}
			start = i + 1
		}
	}
	// Last element
	last := strings.trim_space(inner[start:])
	if len(last) > 0 {
		append(&arr, _parse_value(last, allocator))
	}

	return Toml_Value(arr)
}

_strip_inline_comment :: proc(raw: string) -> string {
	// Don't strip # inside quoted strings
	in_dquote := false
	in_squote := false
	for i := 0; i < len(raw); i += 1 {
		c := raw[i]
		if c == '"' && !in_squote { in_dquote = !in_dquote }
		else if c == '\'' && !in_dquote { in_squote = !in_squote }
		else if c == '#' && !in_dquote && !in_squote {
			return strings.trim_space(raw[:i])
		}
	}
	return raw
}

// ==================== Getters ====================

// toml_get_string retrieves a string value. Returns ok=false if missing or non-string.
toml_get_string :: proc(doc: ^Toml_Document, section, key: string) -> (value: string, ok: bool) {
	val, found := _toml_get_raw(doc, section, key)
	if !found { return "", false }
	if s, is_str := val.(string); is_str {
		return s, true
	}
	return "", false
}

// toml_get_int retrieves an integer value.
toml_get_int :: proc(doc: ^Toml_Document, section, key: string) -> (value: i64, ok: bool) {
	val, found := _toml_get_raw(doc, section, key)
	if !found { return 0, false }
	if i, is_int := val.(i64); is_int {
		return i, true
	}
	return 0, false
}

// toml_get_bool retrieves a boolean value.
toml_get_bool :: proc(doc: ^Toml_Document, section, key: string) -> (value: bool, ok: bool) {
	val, found := _toml_get_raw(doc, section, key)
	if !found { return false, false }
	if b, is_bool := val.(bool); is_bool {
		return b, true
	}
	return false, false
}

// toml_get_array retrieves an array value.
toml_get_array :: proc(doc: ^Toml_Document, section, key: string) -> (value: [dynamic]Toml_Value, ok: bool) {
	val, found := _toml_get_raw(doc, section, key)
	if !found { return {}, false }
	if a, is_arr := val.([dynamic]Toml_Value); is_arr {
		return a, true
	}
	return {}, false
}

// toml_get returns the raw Toml_Value. Use typed getters for convenience.
toml_get :: proc(doc: ^Toml_Document, section, key: string) -> (value: Toml_Value, ok: bool) {
	return _toml_get_raw(doc, section, key)
}

_toml_get_raw :: proc(doc: ^Toml_Document, section, key: string) -> (Toml_Value, bool) {
	if section == "" {
		val, found := doc.root.entries[key]
		return val, found
	}
	table, has_table := doc.tables[section]
	if !has_table {
		return nil, false
	}
	val, found := table.entries[key]
	return val, found
}

// ==================== Setters ====================

// toml_set sets a string value. Creates the section if needed.
toml_set :: proc(doc: ^Toml_Document, section, key, value: string, allocator: mem.Allocator) {
	k := strings.clone(key, allocator)
	v := Toml_Value(strings.clone(value, allocator))

	if section == "" {
		if !(k in doc.root.entries) {
			append(&doc.root.order, k)
		}
		doc.root.entries[k] = v
		return
	}

	if !(section in doc.tables) {
		sec := strings.clone(section, allocator)
		doc.tables[sec] = Toml_Table{
			entries = make(map[string]Toml_Value, 8, allocator),
			order   = make([dynamic]string, 0, 8, allocator),
		}
		append(&doc.table_order, sec)
	}

	table := &doc.tables[section]
	if !(k in table.entries) {
		append(&table.order, k)
	}
	table.entries[k] = v
}

// ==================== Serializer ====================

toml_write :: proc(doc: ^Toml_Document, allocator: mem.Allocator) -> string {
	b := strings.builder_make(0, 256, allocator)

	// Root entries first
	for key in doc.root.order {
		val := doc.root.entries[key]
		strings.write_string(&b, key)
		strings.write_string(&b, " = ")
		_write_value(&b, val)
		strings.write_byte(&b, '\n')
	}

	// Sections in insertion order
	first_section := len(doc.root.order) == 0
	for section in doc.table_order {
		table := doc.tables[section]

		if !first_section {
			strings.write_byte(&b, '\n')
		}
		first_section = false

		strings.write_byte(&b, '[')
		strings.write_string(&b, section)
		strings.write_string(&b, "]\n")

		for key in table.order {
			val := table.entries[key]
			strings.write_string(&b, key)
			strings.write_string(&b, " = ")
			_write_value(&b, val)
			strings.write_byte(&b, '\n')
		}
	}

	return strings.to_string(b)
}

_write_value :: proc(b: ^strings.Builder, val: Toml_Value) {
	switch v in val {
	case string:
		strings.write_byte(b, '"')
		for c in v {
			switch c {
			case '"':  strings.write_string(b, "\\\"")
			case '\\': strings.write_string(b, "\\\\")
			case '\n': strings.write_string(b, "\\n")
			case '\r': strings.write_string(b, "\\r")
			case '\t': strings.write_string(b, "\\t")
			case:      strings.write_rune(b, c)
			}
		}
		strings.write_byte(b, '"')
	case i64:
		strings.write_string(b, fmt.tprintf("%d", v))
	case f64:
		strings.write_string(b, fmt.tprintf("%f", v))
	case bool:
		strings.write_string(b, v ? "true" : "false")
	case [dynamic]Toml_Value:
		strings.write_byte(b, '[')
		for elem, i in v {
			if i > 0 { strings.write_string(b, ", ") }
			_write_value(b, elem)
		}
		strings.write_byte(b, ']')
	case:
		strings.write_string(b, "\"\"")
	}
}
