package platform

import "core:mem"
import "core:strings"

// Minimal TOML parser for mimir.toml and mimir.lock.
// Handles: [section] headers, key = "value" pairs, # comments, empty lines.
// Does NOT handle: multi-line strings, integers, floats, booleans, datetime,
// inline tables, arrays, nested tables, dotted keys.

Toml_Table :: struct {
	entries:    map[string]string,   // key → value
	order:     [dynamic]string,     // insertion order for deterministic output
}

Toml_Document :: struct {
	tables:      map[string]Toml_Table,
	table_order: [dynamic]string,    // section insertion order
	root:        Toml_Table,         // entries before any [section]
}

// Parse TOML source into a document.
toml_parse :: proc(source: string, allocator: mem.Allocator) -> (Toml_Document, Platform_Error) {
	doc := Toml_Document{
		tables      = make(map[string]Toml_Table, 8, allocator),
		table_order = make([dynamic]string, 0, 4, allocator),
		root = Toml_Table{
			entries = make(map[string]string, 8, allocator),
			order   = make([dynamic]string, 0, 4, allocator),
		},
	}

	current_section := ""
	lines := strings.split(source, "\n", allocator)

	for line in lines {
		trimmed := strings.trim_space(line)

		// Skip empty lines and comments
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
					entries = make(map[string]string, 8, allocator),
					order   = make([dynamic]string, 0, 8, allocator),
				}
				append(&doc.table_order, current_section)
			}
			continue
		}

		// Key = value pair
		eq := strings.index(trimmed, "=")
		if eq == -1 {
			continue  // Skip malformed lines
		}

		key := strings.trim_space(trimmed[:eq])
		raw_val := strings.trim_space(trimmed[eq + 1:])

		// Strip quotes from value
		val := _strip_quotes(raw_val)
		key = strings.clone(key, allocator)
		val = strings.clone(val, allocator)

		if current_section == "" {
			// Root table
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

// Look up a value in a section.
toml_get :: proc(doc: ^Toml_Document, section, key: string) -> (value: string, ok: bool) {
	if section == "" {
		val, found := doc.root.entries[key]
		return val, found
	}
	table, has_table := doc.tables[section]
	if !has_table {
		return "", false
	}
	val, found := table.entries[key]
	return val, found
}

// Set a value in a section. Creates the section if it doesn't exist.
toml_set :: proc(doc: ^Toml_Document, section, key, value: string, allocator: mem.Allocator) {
	k := strings.clone(key, allocator)
	v := strings.clone(value, allocator)

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
			entries = make(map[string]string, 8, allocator),
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

// Serialize document back to TOML text.
toml_write :: proc(doc: ^Toml_Document, allocator: mem.Allocator) -> string {
	b := strings.builder_make(0, 256, allocator)

	// Root entries first
	for key in doc.root.order {
		val := doc.root.entries[key]
		strings.write_string(&b, key)
		strings.write_string(&b, " = \"")
		strings.write_string(&b, val)
		strings.write_string(&b, "\"\n")
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
			strings.write_string(&b, " = \"")
			strings.write_string(&b, val)
			strings.write_string(&b, "\"\n")
		}
	}

	return strings.to_string(b)
}

// Strip surrounding quotes (double or single) from a value.
@(private = "file")
_strip_quotes :: proc(s: string) -> string {
	if len(s) < 2 { return s }
	if (s[0] == '"' && s[len(s) - 1] == '"') || (s[0] == '\'' && s[len(s) - 1] == '\'') {
		return s[1:len(s) - 1]
	}
	return s
}
