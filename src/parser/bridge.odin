package parser

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// Bridge is a legacy abstraction from when mimir used a CPython subprocess
// to parse Python files. The native Odin parser now handles all parsing.
// The struct and procs are retained for API compatibility with callers.

Bridge :: struct {
	_unused: u8, // zero-size structs cause issues in some contexts
}

bridge_start :: proc() -> (Bridge, Parse_Error) {
	return Bridge{}, nil
}

bridge_parse :: proc(b: ^Bridge, path: string, allocator: mem.Allocator) -> (^Module, Parse_Error) {
	return parse_native(path, allocator)
}

bridge_stop :: proc(b: ^Bridge) {
	// No-op — no subprocess to stop
}

// Native parser entry point: read file → tokenize → parse → AST.
parse_native :: proc(path: string, allocator: mem.Allocator) -> (^Module, Parse_Error) {
	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		return nil, Bridge_Error{fmt.aprintf("failed to read file: %s", path, allocator = allocator)}
	}
	source := string(data)

	tokens, tok_err := tokenize(source, allocator)
	if tok_err != nil {
		// Add file path to error
		#partial switch &e in tok_err {
		case Syntax_Error:
			e.file = path
		}
		return nil, tok_err
	}

	// Extract PEP 484 type comments (# type: X) from source
	tc_map := extract_type_comments(source, allocator)

	ctx := Parser_Context{
		tokens        = tokens,
		pos           = 0,
		allocator     = allocator,
		file          = path,
		type_comments = &tc_map,
	}

	mod := parse_module_native(&ctx)
	return mod, nil
}

// Extract `# type: X` comments from source text. Returns line→type_string map.
extract_type_comments :: proc(source: string, allocator: mem.Allocator) -> map[i32]string {
	tc := make(map[i32]string, 8, allocator)
	line: i32 = 1
	i := 0
	for i < len(source) {
		if source[i] == '#' {
			// Scan for "type:" after optional whitespace
			j := i + 1
			for j < len(source) && (source[j] == ' ' || source[j] == '\t') { j += 1 }
			rest := source[j:]
			if len(rest) >= 5 && rest[:5] == "type:" {
				after := rest[5:]
				// Trim leading space
				k := 0
				for k < len(after) && (after[k] == ' ' || after[k] == '\t') { k += 1 }
				after = after[k:]
				// Find end of line
				end := 0
				for end < len(after) && after[end] != '\n' && after[end] != '\r' { end += 1 }
				comment := after[:end]
				// Skip "ignore" comments
				if len(comment) > 0 && comment != "ignore" &&
				   !(len(comment) >= 6 && comment[:6] == "ignore") {
					tc[line] = strings.clone(comment, allocator)
				}
			}
			// Skip to end of line
			for i < len(source) && source[i] != '\n' && source[i] != '\r' { i += 1 }
		} else if source[i] == '\n' {
			line += 1
			i += 1
			if i < len(source) && source[i] == '\r' { i += 1 }
		} else if source[i] == '\r' {
			line += 1
			i += 1
			if i < len(source) && source[i] == '\n' { i += 1 }
		} else {
			i += 1
		}
	}
	return tc
}
