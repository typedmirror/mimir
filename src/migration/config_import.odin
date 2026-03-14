package migration

import "core:fmt"
import "core:os"
import "core:strings"
import "core:mem"

Config_Entry :: struct {
	section: string,
	key:     string,
	value:   string,
}

Import_Result :: struct {
	entries:  [dynamic]Config_Entry,
	warnings: [dynamic]string,
}

// Read a mypy config file and translate to mimir.toml equivalents.
import_mypy_config :: proc(path: string, allocator: mem.Allocator) -> (Import_Result, bool) {
	result := Import_Result{
		entries  = make([dynamic]Config_Entry, 0, 16, allocator),
		warnings = make([dynamic]string, 0, 8, allocator),
	}

	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		return result, false
	}
	content := string(data)

	// Detect format from filename
	if strings.has_suffix(path, ".toml") {
		parse_toml_mypy(&result, content, allocator)
	} else {
		// INI format (mypy.ini, setup.cfg)
		parse_ini_mypy(&result, content, allocator)
	}

	return result, true
}

// Parse INI-style config (mypy.ini, setup.cfg)
parse_ini_mypy :: proc(result: ^Import_Result, content: string, allocator: mem.Allocator) {
	in_mypy_section := false
	in_override := false
	last_key := ""
	last_value := ""

	lines := strings.split_lines(content, allocator)
	for line in lines {
		trimmed := strings.trim_space(line)

		// Skip empty lines and comments
		if len(trimmed) == 0 { continue }
		if trimmed[0] == '#' || trimmed[0] == ';' { continue }

		// Section header
		if trimmed[0] == '[' {
			end := strings.index_byte(trimmed, ']')
			if end < 0 { continue }
			section := trimmed[1:end]
			if section == "mypy" {
				in_mypy_section = true
				in_override = false
			} else if strings.has_prefix(section, "mypy-") {
				// Per-module override
				in_mypy_section = false
				in_override = true
			} else {
				in_mypy_section = false
				in_override = false
			}
			continue
		}

		if in_override {
			// Count overrides but don't try to map them
			// (handled once at end)
			continue
		}

		if !in_mypy_section { continue }

		// Continuation line: starts with whitespace, append to previous value
		if (line[0] == ' ' || line[0] == '\t') && len(last_key) > 0 {
			last_value = fmt.aprintf("%s %s", last_value, trimmed, allocator = allocator)
			map_mypy_setting(result, last_key, last_value, allocator)
			continue
		}

		// Key = value
		eq := strings.index_byte(trimmed, '=')
		if eq < 0 {
			// Also try colon (configparser style)
			eq = strings.index_byte(trimmed, ':')
			if eq < 0 { continue }
		}
		key := strings.trim_space(trimmed[:eq])
		value := strings.trim_space(trimmed[eq+1:])
		last_key = key
		last_value = value

		map_mypy_setting(result, key, value, allocator)
	}

	// Check for per-module overrides
	override_count := count_overrides(content, allocator)
	if override_count > 0 {
		warn := fmt.aprintf("%d per-module overrides skipped (mimir uses project-level configuration)", override_count, allocator = allocator)
		append(&result.warnings, warn)
	}
}

// Parse pyproject.toml [tool.mypy] section
parse_toml_mypy :: proc(result: ^Import_Result, content: string, allocator: mem.Allocator) {
	in_mypy_section := false
	in_override := false

	lines := strings.split_lines(content, allocator)
	for line in lines {
		trimmed := strings.trim_space(line)

		if len(trimmed) == 0 { continue }
		if trimmed[0] == '#' { continue }

		// Section header
		if trimmed[0] == '[' {
			if trimmed == "[tool.mypy]" || trimmed == "[mypy]" {
				in_mypy_section = true
				in_override = false
			} else if trimmed == "[[tool.mypy.overrides]]" || strings.has_prefix(trimmed, "[[tool.mypy.overrides") {
				in_mypy_section = false
				in_override = true
			} else {
				in_mypy_section = false
				in_override = false
			}
			continue
		}

		if !in_mypy_section { continue }

		// key = value
		eq := strings.index_byte(trimmed, '=')
		if eq < 0 { continue }
		key := strings.trim_space(trimmed[:eq])
		value := strings.trim_space(trimmed[eq+1:])
		// Strip quotes from TOML values
		value = strip_quotes(value)

		map_mypy_setting(result, key, value, allocator)
	}

	if in_override {
		append(&result.warnings, "Per-module overrides in [tool.mypy.overrides] skipped (mimir uses project-level configuration)")
	}
}

// Map a single mypy setting to mimir equivalent
map_mypy_setting :: proc(result: ^Import_Result, key, value: string, allocator: mem.Allocator) {
	switch key {
	case "python_version":
		append(&result.entries, Config_Entry{
			section = "project",
			key     = "requires-python",
			value   = fmt.aprintf(">=%s", value, allocator = allocator),
		})
	case "strict":
		if value == "True" || value == "true" {
			append(&result.entries, Config_Entry{
				section = "check",
				key     = "strict",
				value   = "true",
			})
		}
	case "disallow_untyped_defs":
		if value == "True" || value == "true" {
			append(&result.entries, Config_Entry{
				section = "check",
				key     = "require-annotations",
				value   = "true",
			})
		}
	case "warn_return_any":
		if value == "True" || value == "true" {
			append(&result.entries, Config_Entry{
				section = "check",
				key     = "warn-return-any",
				value   = "true",
			})
		}
	case "warn_unused_ignores":
		if value == "True" || value == "true" {
			append(&result.entries, Config_Entry{
				section = "check",
				key     = "warn-unused-ignores",
				value   = "true",
			})
		}
	case "ignore_missing_imports":
		if value == "True" || value == "true" {
			append(&result.entries, Config_Entry{
				section = "check",
				key     = "ignore-missing-imports",
				value   = "true",
			})
		}
	case "exclude":
		append(&result.entries, Config_Entry{
			section = "check",
			key     = "exclude",
			value   = value,
		})
	case "plugins":
		warn := fmt.aprintf("'plugins = %s' has no mimir equivalent (plugin support not yet available)", value, allocator = allocator)
		append(&result.warnings, warn)
	case "follow_imports":
		warn := fmt.aprintf("'follow_imports = %s' has no mimir equivalent (mimir always follows imports)", value, allocator = allocator)
		append(&result.warnings, warn)
	case "mypy_path":
		warn := fmt.aprintf("'mypy_path = %s' has no mimir equivalent (mimir uses its own module resolution)", value, allocator = allocator)
		append(&result.warnings, warn)
	case "namespace_packages":
		warn := fmt.aprintf("'namespace_packages = %s' has no mimir equivalent", value, allocator = allocator)
		append(&result.warnings, warn)
	case "check_untyped_defs":
		if value == "True" || value == "true" {
			append(&result.entries, Config_Entry{
				section = "check",
				key     = "check-untyped-defs",
				value   = "true",
			})
		}
	case "disallow_any_generics", "disallow_incomplete_defs",
	     "no_implicit_optional", "warn_redundant_casts",
	     "disallow_untyped_calls", "disallow_untyped_decorators":
		// These are subsumed by strict mode
		if value == "True" || value == "true" {
			mapped_key, _ := strings.replace(key, "_", "-", -1, allocator)
			append(&result.entries, Config_Entry{
				section = "check",
				key     = mapped_key,
				value   = "true",
			})
		}
	case:
		// Unknown setting
		warn := fmt.aprintf("'%s = %s' has no known mimir equivalent", key, value, allocator = allocator)
		append(&result.warnings, warn)
	}
}

strip_quotes :: proc(s: string) -> string {
	if len(s) >= 2 {
		if (s[0] == '"' && s[len(s)-1] == '"') || (s[0] == '\'' && s[len(s)-1] == '\'') {
			return s[1:len(s)-1]
		}
	}
	return s
}

count_overrides :: proc(content: string, allocator: mem.Allocator) -> int {
	count := 0
	lines := strings.split_lines(content, allocator)
	for line in lines {
		trimmed := strings.trim_space(line)
		if len(trimmed) > 0 && trimmed[0] == '[' {
			end := strings.index_byte(trimmed, ']')
			if end > 0 {
				section := trimmed[1:end]
				if strings.has_prefix(section, "mypy-") {
					count += 1
				}
			}
		}
	}
	return count
}

// Print the import result as mimir.toml
print_import_result :: proc(result: ^Import_Result) {
	if len(result.entries) == 0 && len(result.warnings) == 0 {
		fmt.println("No mypy settings found.")
		return
	}

	if len(result.entries) > 0 {
		fmt.println("Generated mimir.toml settings:\n")

		// Group by section
		current_section := ""
		for entry in result.entries {
			if entry.section != current_section {
				if len(current_section) > 0 { fmt.println() }
				fmt.printfln("[%s]", entry.section)
				current_section = entry.section
			}
			fmt.printfln("%s = \"%s\"", entry.key, entry.value)
		}
		fmt.println()
	}

	if len(result.warnings) > 0 {
		fmt.println("Warnings:")
		for warn in result.warnings {
			fmt.printfln("  - %s", warn)
		}
		fmt.println()
	}
}
