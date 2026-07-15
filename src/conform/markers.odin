package conform

import "core:fmt"
import "core:strings"
import "core:mem"

Marker_Kind :: enum u8 {
	Required,
	Optional,
}

Marker :: struct {
	line:  int,
	kind:  Marker_Kind,
	text:  string,
	codes: []string, // empty = legacy line-level marker; non-empty = code-specific
}

// Marker_Error reports a malformed marker. Malformed markers are hard
// failures for the whole test file: an author who wrote an opening bracket
// meant a code marker, and silently asserting less (degrading to a bare
// line-level marker, or skipping) would be instrument self-deception.
Marker_Error :: struct {
	line: int,
	msg:  string,
}

// parse_markers scans source lines for end-of-line `# E` markers.
// Supported formats:
//   # E                → required error on this line (line-level, legacy)
//   # E?               → optional error (not a failure if missed)
//   # E: text          → required error with informational text
//   # E[CODE]          → required error with this exact diagnostic code
//   # E[CODE1|CODE2]   → required error matching any one of the listed codes
//   # E[CODE]: text    → code-specific marker with informational text
//   # E?[CODE]         → optional code-specific marker
// Codes are uppercase ASCII letters followed by digits (e.g. T001, SEC010).
// Legacy formats keep their exact pre-T3a semantics.
// Malformed bracket markers (unclosed bracket, empty code list, invalid
// code text) are returned as Marker_Error values — the runner must fail
// the file loudly, never degrade to a weaker assertion.
// One marker per line; the rightmost `# E` occurrence wins (legacy behavior).
parse_markers :: proc(source: []byte, allocator: mem.Allocator) -> ([]Marker, []Marker_Error) {
	markers: [dynamic]Marker
	markers.allocator = allocator
	errors: [dynamic]Marker_Error
	errors.allocator = allocator

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
		codes: []string

		if len(rest) == 0 {
			// bare `# E`
		} else if rest[0] == '[' {
			// `# E[CODE]` or `# E[CODE1|CODE2]` — code-specific marker
			ok: bool
			codes, text, ok = _parse_code_marker(rest, 0, line_num, &errors, allocator)
			if !ok do continue // malformed — error recorded, runner fails the file
		} else if rest[0] == '?' {
			kind = .Optional
			if len(rest) > 1 && rest[1] == '[' {
				// `# E?[CODE]` — optional code-specific marker
				ok: bool
				codes, text, ok = _parse_code_marker(rest, 1, line_num, &errors, allocator)
				if !ok do continue
			}
			// else: legacy — anything after `?` is ignored
		} else if rest[0] == ':' {
			// `# E: explanation text`
			text = strings.trim_left_space(rest[1:])
		} else if rest[0] == ' ' {
			// Could be `# E ` (trailing space) — treat as required.
			// NOTE: a bracket after the space (`# E [CODE]`) stays a legacy
			// bare marker; only a bracket IMMEDIATELY after `# E`/`# E?`
			// enters the code-marker path (preserves legacy byte-for-byte).
		} else {
			// Not a valid marker (e.g., `# ERROR`, `# Example`)
			continue
		}

		append(&markers, Marker{
			line = line_num,
			kind = kind,
			text = strings.clone(text, allocator) if len(text) > 0 else "",
			codes = codes,
		})
	}

	return markers[:], errors[:]
}

// _parse_code_marker parses `[CODE]` / `[CODE1|CODE2]` with rest[open_idx] == '['.
// Returns the parsed codes, any trailing `: text`, and ok=false (with a
// recorded Marker_Error) on malformed input.
@(private = "file")
_parse_code_marker :: proc(
	rest: string,
	open_idx: int,
	line_num: int,
	errors: ^[dynamic]Marker_Error,
	allocator: mem.Allocator,
) -> (codes: []string, text: string, ok: bool) {
	inner_start := open_idx + 1
	close_rel := strings.index_byte(rest[inner_start:], ']')
	if close_rel < 0 {
		append(errors, Marker_Error{
			line = line_num,
			msg  = strings.clone("unclosed '[' - expected '[CODE]' or '[CODE1|CODE2]' after the E", allocator),
		})
		return
	}
	inner := rest[inner_start : inner_start + close_rel]
	if len(strings.trim_space(inner)) == 0 {
		append(errors, Marker_Error{
			line = line_num,
			msg  = strings.clone("empty code list '[]' - expected '[CODE]' after the E", allocator),
		})
		return
	}

	parts := strings.split(inner, "|", context.temp_allocator)
	out: [dynamic]string
	out.allocator = allocator
	for p in parts {
		c := strings.trim_space(p)
		if len(c) == 0 {
			append(errors, Marker_Error{
				line = line_num,
				msg  = strings.clone(fmt.tprintf("empty code in code list '[%s]'", inner), allocator),
			})
			return
		}
		if !_is_valid_code(c) {
			append(errors, Marker_Error{
				line = line_num,
				msg  = strings.clone(fmt.tprintf("invalid code '%s' in '[%s]' - codes are uppercase letters followed by digits (e.g. T001, SEC010)", c, inner), allocator),
			})
			return
		}
		append(&out, strings.clone(c, allocator))
	}

	// After ']': allow end of line, ': text', or whitespace + trailing commentary.
	after := rest[inner_start + close_rel + 1:]
	if len(after) > 0 {
		if after[0] == ':' {
			text = strings.trim_left_space(after[1:])
		} else if after[0] == ' ' || after[0] == '\t' {
			// trailing commentary ignored (matches legacy `# E ` behavior)
		} else {
			append(errors, Marker_Error{
				line = line_num,
				msg  = strings.clone(fmt.tprintf("unexpected '%c' after ']' - allowed: end of line, ': text', or whitespace", rune(after[0])), allocator),
			})
			return
		}
	}

	return out[:], text, true
}

// _is_valid_code reports whether s looks like a diagnostic code:
// one or more uppercase ASCII letters followed by one or more digits.
@(private = "file")
_is_valid_code :: proc(s: string) -> bool {
	i := 0
	for i < len(s) && s[i] >= 'A' && s[i] <= 'Z' do i += 1
	if i == 0 do return false // must start with letters
	j := i
	for j < len(s) && s[j] >= '0' && s[j] <= '9' do j += 1
	if j == i do return false // must have digits
	return j == len(s) // nothing after the digits
}
