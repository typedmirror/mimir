package platform

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// PEP 723 inline script metadata parser.
// Extracts dependency specs and python version from script comments.

Dep_Spec :: struct {
	name:       string,   // "flask"
	constraint: string,   // ">=3.0" or "" for unconstrained
	raw:        string,   // "flask>=3.0" (passed to pip as-is)
}

Script_Metadata :: struct {
	dependencies:   [dynamic]Dep_Spec,
	python_version: string,   // "" if not specified
	has_metadata:   bool,
}

// Parse PEP 723 metadata from a Python script file.
parse_script_metadata :: proc(path: string, allocator: mem.Allocator) -> (Script_Metadata, Platform_Error) {
	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		return {}, Platform_Error_Data{msg = fmt.tprintf("cannot read '%s': %v", path, read_err)}
	}

	return parse_metadata_from_source(string(data), allocator)
}

// Parse PEP 723 metadata from source text.
// Looks for:
//   # /// script
//   # dependencies = ["flask>=3.0", "requests"]
//   # requires-python = ">=3.12"
//   # ///
parse_metadata_from_source :: proc(source: string, allocator: mem.Allocator) -> (Script_Metadata, Platform_Error) {
	result := Script_Metadata{
		dependencies = make([dynamic]Dep_Spec, 0, 4, allocator),
	}

	lines := strings.split(source, "\n", allocator)

	// Find start marker: # /// script
	start := -1
	for line, i in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "# /// script" {
			start = i
			break
		}
	}
	if start == -1 {
		return result, nil  // No metadata block — not an error
	}

	// Collect lines until end marker: # ///
	end := -1
	for i := start + 1; i < len(lines); i += 1 {
		trimmed := strings.trim_space(lines[i])
		if trimmed == "# ///" {
			end = i
			break
		}
	}
	if end == -1 {
		return {}, Platform_Error_Data{msg = "PEP 723: found '# /// script' but no closing '# ///'"}
	}

	result.has_metadata = true

	// Parse content lines (strip "# " prefix)
	for i := start + 1; i < end; i += 1 {
		line := strings.trim_space(lines[i])
		if !strings.has_prefix(line, "# ") {
			continue
		}
		content := line[2:]  // strip "# "

		if strings.has_prefix(content, "dependencies") {
			// Handle multi-line arrays: accumulate lines until "]" is found
			accumulated := content
			if strings.index(content, "[") != -1 && strings.last_index(content, "]") == -1 {
				// Opening bracket found but no closing — accumulate continuation lines
				parts := make([dynamic]string, 0, 8, allocator)
				append(&parts, content)
				for i += 1; i < end; i += 1 {
					cont_line := strings.trim_space(lines[i])
					if !strings.has_prefix(cont_line, "# ") { continue }
					cont := cont_line[2:]
					append(&parts, cont)
					if strings.contains(cont, "]") { break }
				}
				accumulated = strings.concatenate(parts[:], allocator)
			}
			deps_err := _parse_dependencies(accumulated, &result, allocator)
			if deps_err != nil {
				return {}, deps_err
			}
		} else if strings.has_prefix(content, "requires-python") {
			// Parse: requires-python = ">=3.12"
			_parse_requires_python(content, &result)
		}
	}

	return result, nil
}

// Parse a dependency spec string like "flask>=3.0" into name + constraint.
parse_dep_spec :: proc(raw: string, allocator: mem.Allocator) -> Dep_Spec {
	trimmed := strings.trim_space(raw)

	// Version operators to split on (check longest first)
	operators := [?]string{">=", "<=", "~=", "!=", "==", ">", "<"}
	for op in operators {
		if idx := strings.index(trimmed, op); idx >= 0 {
			return Dep_Spec{
				name       = strings.trim_space(trimmed[:idx]),
				constraint = trimmed[idx:],
				raw        = trimmed,
			}
		}
	}

	// No version constraint
	return Dep_Spec{
		name = trimmed,
		raw  = trimmed,
	}
}

// Parse dependencies = ["pkg1", "pkg2>=1.0"]
@(private = "file")
_parse_dependencies :: proc(content: string, result: ^Script_Metadata, allocator: mem.Allocator) -> Platform_Error {
	// Find the array brackets
	open := strings.index(content, "[")
	close := strings.last_index(content, "]")
	if open == -1 || close == -1 || close <= open {
		return Platform_Error_Data{msg = "PEP 723: malformed dependencies array"}
	}

	inner := content[open + 1:close]
	if strings.trim_space(inner) == "" {
		return nil  // Empty array
	}

	// Split by comma, parse each quoted string
	parts := strings.split(inner, ",", allocator)
	for part in parts {
		trimmed := strings.trim_space(part)
		// Strip quotes
		if len(trimmed) >= 2 && trimmed[0] == '"' && trimmed[len(trimmed) - 1] == '"' {
			trimmed = trimmed[1:len(trimmed) - 1]
		}
		if trimmed == "" {
			continue
		}
		append(&result.dependencies, parse_dep_spec(trimmed, allocator))
	}

	return nil
}

// Parse requires-python = ">=3.12"
@(private = "file")
_parse_requires_python :: proc(content: string, result: ^Script_Metadata) {
	eq := strings.index(content, "=")
	if eq == -1 { return }
	val := strings.trim_space(content[eq + 1:])
	// Strip quotes
	if len(val) >= 2 && val[0] == '"' && val[len(val) - 1] == '"' {
		result.python_version = val[1:len(val) - 1]
	}
}
