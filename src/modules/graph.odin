package modules

import "core:slice"
import "core:strings"
import "core:mem"

import parser "mimir:parser"
import binder "mimir:binder"
import core   "mimir:core"

// ==================== Module Info ====================

Module_Info :: struct {
	qualified_name: string,
	file_path:      string,
	is_package:     bool,           // __init__.py
	parse_result:   ^parser.Module,
	bind_result:    binder.Bind_Result,
	imports:        [dynamic]Import_Edge,
}

Import_Edge :: struct {
	target_module: string,              // qualified name of target
	names:         []binder.Import_Name, // specific names (from X import Y)
	is_star:       bool,
	is_whole:      bool,                // import X (not from X import Y)
	loc:           parser.Src_Loc,
}

// ==================== Module Graph ====================

Module_Graph :: struct {
	modules:    map[string]^Module_Info, // qualified_name → info
	root_path:  string,                  // project root directory
	topo_order: [dynamic]string,         // analysis order
	has_cycles: bool,
	allocator:  mem.Allocator,
}

// ==================== Discovery ====================

discover_modules :: proc(root_path: string, files: []string, allocator: mem.Allocator) -> Module_Graph {
	graph: Module_Graph
	graph.root_path = root_path
	graph.allocator = allocator
	graph.modules = make(map[string]^Module_Info, len(files), allocator)
	graph.topo_order = make([dynamic]string, 0, len(files), allocator)

	// Compute root from file paths (handles absolute/relative mismatch)
	root := compute_root_from_files(files, allocator)

	for file in files {
		info := new(Module_Info, allocator)
		info.file_path = file
		info.imports = make([dynamic]Import_Edge, 0, 8, allocator)

		// Compute qualified name from file path relative to root
		rel := file
		if strings.has_prefix(file, root) {
			rel = file[len(root):]
		}

		// Check for __init__.py
		if strings.has_suffix(rel, "__init__.py") {
			info.is_package = true
			// Remove /__init__.py or __init__.py to get package path
			pkg_path := rel[:len(rel) - len("__init__.py")]
			if len(pkg_path) > 0 && pkg_path[len(pkg_path) - 1] == '/' {
				pkg_path = pkg_path[:len(pkg_path) - 1]
			}
			info.qualified_name = path_to_qualified(pkg_path, allocator)
		} else {
			// Remove .py suffix
			without_py := rel[:len(rel) - 3]
			info.qualified_name = path_to_qualified(without_py, allocator)
		}

		graph.modules[info.qualified_name] = info
	}

	return graph
}

// Convert file path segments to dotted qualified name
// e.g., "pkg/sub" → "pkg.sub", "utils" → "utils"
path_to_qualified :: proc(path: string, allocator: mem.Allocator) -> string {
	if len(path) == 0 { return "" }

	buf := make([dynamic]u8, 0, len(path), allocator)
	for i := 0; i < len(path); i += 1 {
		if path[i] == '/' {
			append(&buf, '.')
		} else {
			append(&buf, path[i])
		}
	}
	return string(buf[:])
}

// ==================== Import Edge Building ====================

build_import_edges :: proc(graph: ^Module_Graph) {
	for _, info in graph.modules {
		for imp in info.bind_result.imports {
			edge: Import_Edge
			edge.loc = imp.loc
			edge.is_star = imp.is_star

			if len(imp.names) == 0 && !imp.is_star {
				// "import X" — whole module import
				edge.is_whole = true
				edge.target_module = resolve_module_name(
					imp.module_name, imp.level, info.qualified_name, info.is_package, graph)
			} else {
				// "from X import Y" or "from X import *"
				edge.is_whole = false
				edge.names = imp.names
				edge.target_module = resolve_module_name(
					imp.module_name, imp.level, info.qualified_name, info.is_package, graph)
			}

			append(&info.imports, edge)
		}
	}
}

// Resolve a module name, handling relative imports
resolve_module_name :: proc(
	module_name: string,
	level: int,
	current_module: string,
	is_package: bool,
	graph: ^Module_Graph,
) -> string {
	if level == 0 {
		return module_name
	}

	// Relative import: compute base package
	parts := split_qualified(current_module, graph.allocator)

	// For packages (__init__.py), the module IS the package.
	// level=1 means "this package" (drop 0), level=2 means "parent" (drop 1).
	// For regular modules, level=1 means "my package" (drop 1 = remove module name).
	n_drop := level
	if is_package {
		n_drop = level - 1
	}
	keep := len(parts) - n_drop
	if keep < 0 { keep = 0 }
	base_parts := parts[:keep]

	if len(module_name) == 0 {
		// "from . import X" → just the package
		return join_qualified(base_parts, graph.allocator)
	}

	if len(base_parts) == 0 {
		return module_name
	}

	base := join_qualified(base_parts, graph.allocator)
	buf := make([dynamic]u8, 0, len(base) + 1 + len(module_name), graph.allocator)
	for c in base { append(&buf, u8(c)) }
	append(&buf, '.')
	for c in module_name { append(&buf, u8(c)) }
	return string(buf[:])
}

split_qualified :: proc(name: string, allocator: mem.Allocator) -> []string {
	if len(name) == 0 { return nil }

	parts := make([dynamic]string, 0, 4, allocator)
	start := 0
	for i := 0; i < len(name); i += 1 {
		if name[i] == '.' {
			append(&parts, name[start:i])
			start = i + 1
		}
	}
	append(&parts, name[start:])
	return parts[:]
}

join_qualified :: proc(parts: []string, allocator: mem.Allocator) -> string {
	if len(parts) == 0 { return "" }
	if len(parts) == 1 { return parts[0] }

	total := 0
	for p in parts { total += len(p) }
	total += len(parts) - 1 // dots

	buf := make([dynamic]u8, 0, total, allocator)
	for p, i in parts {
		if i > 0 { append(&buf, '.') }
		for c in p { append(&buf, u8(c)) }
	}
	return string(buf[:])
}

// ==================== Root Path Computation ====================

// Compute the common directory prefix from file paths
// Handles both absolute and relative file paths
compute_root_from_files :: proc(files: []string, allocator: mem.Allocator) -> string {
	if len(files) == 0 { return "" }
	if len(files) == 1 {
		// Root is the directory containing the single file
		return dirname(files[0], allocator)
	}

	// Find longest common prefix of all file paths
	prefix := files[0]
	for f in files[1:] {
		prefix = common_prefix(prefix, f)
	}

	// Trim to last '/' to get a directory
	for i := len(prefix) - 1; i >= 0; i -= 1 {
		if prefix[i] == '/' {
			return prefix[:i + 1]
		}
	}
	return ""
}

common_prefix :: proc(a: string, b: string) -> string {
	n := min(len(a), len(b))
	i := 0
	for i < n && a[i] == b[i] {
		i += 1
	}
	return a[:i]
}

dirname :: proc(path: string, allocator: mem.Allocator) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' {
			return path[:i + 1]
		}
	}
	return ""
}

// ==================== Topological Sort ====================

topological_sort :: proc(graph: ^Module_Graph, diagnostics: ^[dynamic]core.Diagnostic) {
	// Kahn's algorithm
	// Edge semantics: if A imports B, A depends on B, B must come first
	// in_degree[A] = number of project-internal modules A depends on

	in_degree := make(map[string]int, len(graph.modules), graph.allocator)

	// Initialize all in-degrees to 0
	for name, _ in graph.modules {
		in_degree[name] = 0
	}

	// Count dependencies
	for name, info in graph.modules {
		for edge in info.imports {
			if edge.target_module in graph.modules {
				if deg, ok := in_degree[name]; ok {
					in_degree[name] = deg + 1
				}
			}
		}
	}

	// Initialize queue with zero-dependency modules (sorted for determinism)
	queue := make([dynamic]string, 0, len(graph.modules), graph.allocator)
	for name, deg in in_degree {
		if deg == 0 {
			append(&queue, name)
		}
	}
	slice.sort(queue[:])

	// Process
	clear(&graph.topo_order)
	processed := 0
	queue_head := 0

	for queue_head < len(queue) {
		name := queue[queue_head]
		queue_head += 1
		append(&graph.topo_order, name)
		processed += 1

		// For each module that depends on 'name', reduce in-degree
		// Collect newly ready modules, then sort for deterministic ordering
		newly_ready := make([dynamic]string, 0, 4, graph.allocator)
		for other_name, other_info in graph.modules {
			for edge in other_info.imports {
				if edge.target_module == name {
					if deg, ok := in_degree[other_name]; ok {
						in_degree[other_name] = deg - 1
						if deg - 1 == 0 {
							append(&newly_ready, other_name)
						}
					}
				}
			}
		}
		slice.sort(newly_ready[:])
		for nr in newly_ready {
			append(&queue, nr)
		}
	}

	// Check for cycles
	if processed < len(graph.modules) {
		graph.has_cycles = true
		// Add remaining cycle members in sorted order (deterministic)
		remaining := make([dynamic]string, 0, len(graph.modules), graph.allocator)
		for name, _ in graph.modules {
			found := false
			for ordered in graph.topo_order {
				if ordered == name { found = true; break }
			}
			if !found {
				append(&remaining, name)
			}
		}
		slice.sort(remaining[:])
		for r in remaining {
			append(&graph.topo_order, r)
		}

		if diagnostics != nil {
			append(diagnostics, core.Diagnostic{
				severity = .Warning,
				location = core.Location{},
				code = "M001",
				what = "circular import detected",
				why  = "modules form an import cycle; some types may be unknown",
				fix  = "refactor to break the circular dependency",
			})
		}
	}
}
