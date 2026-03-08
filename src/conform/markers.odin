package conform

import "core:strings"
import "core:mem"

Marker_Kind :: enum u8 {
	Required,
	Optional,
}

Marker :: struct {
	line: int,
	kind: Marker_Kind,
	text: string,
}

// parse_markers scans source lines for end-of-line `# E` markers.
// Supported formats:
//   # E           → required error on this line
//   # E?          → optional error (not a failure if missed)
//   # E: text     → required error with informational text
parse_markers :: proc(source: []byte, allocator: mem.Allocator) -> []Marker {
	markers: [dynamic]Marker
	markers.allocator = allocator

	src := string(source)
	line_num := 0
	for line in strings.split_lines_iterator(&src) {
		line_num += 1

		// Find `# E` marker — search from the right for comment markers
		idx := strings.last_index(line, "# E")
		if idx < 0 do continue

		// Must be preceded by whitespace or be at start of line
		if idx > 0 && line[idx - 1] != ' ' && line[idx - 1] != '\t' {
			continue
		}

		rest := line[idx + 3:]

		kind := Marker_Kind.Required
		text := ""

		if len(rest) == 0 {
			// bare `# E`
		} else if rest[0] == '?' {
			kind = .Optional
		} else if rest[0] == ':' {
			// `# E: explanation text`
			text = strings.trim_left_space(rest[1:])
		} else if rest[0] == ' ' {
			// Could be `# E ` (trailing space) — treat as required
		} else {
			// Not a valid marker (e.g., `# ERROR`, `# Example`)
			continue
		}

		append(&markers, Marker{
			line = line_num,
			kind = kind,
			text = strings.clone(text, allocator) if len(text) > 0 else "",
		})
	}

	return markers[:]
}
