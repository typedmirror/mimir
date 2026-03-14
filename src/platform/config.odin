package platform

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// Project configuration from mimir.toml.

Project_Config :: struct {
	name:            string,
	requires_python: string,
	dependencies:    [dynamic]Dep_Spec,
	file_path:       string,              // where mimir.toml was found
}

// Read mimir.toml from a path.
read_config :: proc(path: string, allocator: mem.Allocator) -> (Project_Config, Platform_Error) {
	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		return {}, Platform_Error_Data{msg = fmt.tprintf("cannot read '%s': %v", path, read_err)}
	}

	doc, parse_err := toml_parse(string(data), allocator)
	if parse_err != nil {
		return {}, parse_err
	}

	config := Project_Config{
		dependencies = make([dynamic]Dep_Spec, 0, 8, allocator),
		file_path    = strings.clone(path, allocator),
	}

	// Read [project] section
	if name, ok := toml_get(&doc, "project", "name"); ok {
		config.name = name
	}
	if rp, ok := toml_get(&doc, "project", "requires-python"); ok {
		config.requires_python = rp
	}

	// Read [dependencies] section — keys are package names, values are constraints
	if deps_table, has_deps := doc.tables["dependencies"]; has_deps {
		for dep_name in deps_table.order {
			constraint := deps_table.entries[dep_name]
			raw: string
			if constraint == "" {
				raw = dep_name
			} else {
				raw = strings.concatenate({dep_name, constraint}, allocator)
			}
			append(&config.dependencies, Dep_Spec{
				name       = dep_name,
				constraint = constraint,
				raw        = raw,
			})
		}
	}

	return config, nil
}

// Write a Project_Config to mimir.toml.
write_config :: proc(config: ^Project_Config, path: string, allocator: mem.Allocator) -> Platform_Error {
	doc := Toml_Document{
		tables      = make(map[string]Toml_Table, 4, allocator),
		table_order = make([dynamic]string, 0, 4, allocator),
		root = Toml_Table{
			entries = make(map[string]string, 4, allocator),
			order   = make([dynamic]string, 0, 4, allocator),
		},
	}

	// [project] section
	if config.name != "" {
		toml_set(&doc, "project", "name", config.name, allocator)
	}
	if config.requires_python != "" {
		toml_set(&doc, "project", "requires-python", config.requires_python, allocator)
	}

	// [dependencies] section
	for dep in config.dependencies {
		toml_set(&doc, "dependencies", dep.name, dep.constraint, allocator)
	}

	content := toml_write(&doc, allocator)
	write_err := os.write_entire_file(path, transmute([]u8)content)
	if write_err != nil {
		return Platform_Error_Data{msg = fmt.tprintf("cannot write '%s': %v", path, write_err)}
	}

	return nil
}

// Walk up the directory tree from start_dir looking for mimir.toml.
find_config :: proc(start_dir: string, allocator: mem.Allocator) -> (path: string, found: bool) {
	dir := start_dir

	for {
		candidate := strings.concatenate({dir, "/mimir.toml"}, allocator)
		if os.is_file(candidate) {
			return candidate, true
		}

		// Go up one level
		parent := parent_dir(dir)
		if parent == dir || parent == "" {
			break  // Reached root
		}
		dir = parent
	}

	return "", false
}

// Add or update a dependency in the config. Does not write to disk.
add_dependency :: proc(config: ^Project_Config, name, constraint: string, allocator: mem.Allocator) {
	// Check if it already exists — update in place
	for &dep in config.dependencies {
		if dep.name == name {
			dep.constraint = constraint
			if constraint == "" {
				dep.raw = name
			} else {
				dep.raw = strings.concatenate({name, constraint}, allocator)
			}
			return
		}
	}

	// Add new
	raw: string
	if constraint == "" {
		raw = name
	} else {
		raw = strings.concatenate({name, constraint}, allocator)
	}
	append(&config.dependencies, Dep_Spec{
		name       = name,
		constraint = constraint,
		raw        = raw,
	})
}

// Remove a dependency by name. Returns true if found and removed.
remove_dependency :: proc(config: ^Project_Config, name: string) -> bool {
	for i := 0; i < len(config.dependencies); i += 1 {
		if config.dependencies[i].name == name {
			ordered_remove(&config.dependencies, i)
			return true
		}
	}
	return false
}

// Create a new default config for `mimir add` when no mimir.toml exists.
default_config :: proc(dir: string, allocator: mem.Allocator) -> Project_Config {
	// Derive project name from directory name
	proj_name := _dir_basename(dir)
	return Project_Config{
		name         = proj_name,
		dependencies = make([dynamic]Dep_Spec, 0, 8, allocator),
		file_path    = strings.concatenate({dir, "/mimir.toml"}, allocator),
	}
}

// Get the basename of a directory path.
@(private = "file")
_dir_basename :: proc(path: string) -> string {
	s := path
	// Strip trailing slash
	if len(s) > 1 && s[len(s) - 1] == '/' {
		s = s[:len(s) - 1]
	}
	for i := len(s) - 1; i >= 0; i -= 1 {
		if s[i] == '/' {
			return s[i + 1:]
		}
	}
	return s
}
