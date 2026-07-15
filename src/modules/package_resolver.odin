package modules

import "core:mem"
import "core:os"
import "core:strings"

import parser   "mimir:parser"
import binder   "mimir:binder"
import checker  "mimir:checker"
import flow     "mimir:flow"
import platform "mimir:platform"

// Resolve a third-party module name to a file in the package cache.
// Returns the file path and whether it was found.
// Priority: .pyi > .py (PEP 561).
resolve_package_file :: proc(
	module_name: string,
	cache: ^platform.Cache,
	allocator: mem.Allocator,
) -> (file_path: string, found: bool) {
	// Extract top-level package name: "flask.views" → "flask"
	top := module_name
	sub_path := ""
	for i := 0; i < len(module_name); i += 1 {
		if module_name[i] == '.' {
			top = module_name[:i]
			sub_path = module_name[i+1:]
			break
		}
	}

	// Find any version of this package in the cache
	pkg_dir := strings.concatenate({cache.packages, "/", top}, allocator)
	if !os.is_directory(pkg_dir) { return "", false }

	// Find the first version directory (or use pkg_dir if unversioned)
	version_dir := ""
	ver_entries, ver_err := os.read_all_directory_by_path(pkg_dir, allocator)
	if ver_err == nil {
		for entry in ver_entries {
			if entry.type == .Directory {
				// Skip dist-info directories
				if strings.has_suffix(entry.name, ".dist-info") { continue }
				// Check if this looks like a version directory (has the package inside)
				candidate := strings.concatenate({pkg_dir, "/", entry.name}, allocator)
				inner_pkg := strings.concatenate({candidate, "/", top}, allocator)
				if os.is_directory(inner_pkg) {
					version_dir = candidate
					break
				}
				// Also check if the package files are directly in this dir
				init_py := strings.concatenate({candidate, "/__init__.py"}, allocator)
				if os.is_file(init_py) {
					// This IS the package dir (unversioned layout)
					version_dir = pkg_dir
					break
				}
			}
		}
	}

	if len(version_dir) == 0 {
		// Try unversioned layout: packages/<name>/<name>/__init__.py
		inner := strings.concatenate({pkg_dir, "/", top}, allocator)
		if os.is_directory(inner) {
			version_dir = pkg_dir
		} else {
			return "", false
		}
	}

	// Now resolve the module path within the package
	// Base: version_dir/<top>/
	pkg_root := strings.concatenate({version_dir, "/", top}, allocator)
	if !os.is_directory(pkg_root) { return "", false }

	if len(sub_path) == 0 {
		// "import flask" → flask/__init__.pyi or flask/__init__.py
		pyi := strings.concatenate({pkg_root, "/__init__.pyi"}, allocator)
		if os.is_file(pyi) { return pyi, true }
		py := strings.concatenate({pkg_root, "/__init__.py"}, allocator)
		if os.is_file(py) { return py, true }
		return "", false
	}

	// "import flask.views" → flask/views.pyi or flask/views.py
	// Convert dots to slashes for sub-path
	sub_file := sub_path
	buf := make([dynamic]u8, 0, len(sub_path), allocator)
	for c in sub_path {
		if c == '.' {
			append(&buf, '/')
		} else {
			append(&buf, u8(c))
		}
	}
	sub_file = string(buf[:])

	// Try as file: flask/views.pyi, flask/views.py
	pyi := strings.concatenate({pkg_root, "/", sub_file, ".pyi"}, allocator)
	if os.is_file(pyi) { return pyi, true }
	py := strings.concatenate({pkg_root, "/", sub_file, ".py"}, allocator)
	if os.is_file(py) { return py, true }

	// Try as package: flask/views/__init__.pyi, flask/views/__init__.py
	pyi_init := strings.concatenate({pkg_root, "/", sub_file, "/__init__.pyi"}, allocator)
	if os.is_file(pyi_init) { return pyi_init, true }
	py_init := strings.concatenate({pkg_root, "/", sub_file, "/__init__.py"}, allocator)
	if os.is_file(py_init) { return py_init, true }

	return "", false
}

// Parse a cached package file and extract its module-level exports.
// Uses the existing parse → bind → check pipeline.
// Resolves relative imports within the package to get re-exported types.
extract_package_exports :: proc(
	file_path: string,
	module_name: string,
	bridge: ^parser.Bridge,
	registry: ^checker.Type_Registry,
	allocator: mem.Allocator,
	res_ctx: ^Resolution_Context = nil,
) -> (exports: Module_Exports, ok: bool) {
	// Determine package root directory from file path
	// e.g., /path/flask/__init__.py → /path/flask/
	pkg_root := _parent_dir(file_path)

	// Parse the main file
	module, parse_err := parser.bridge_parse(bridge, file_path, allocator)
	if parse_err != nil { return {}, false }

	// Bind
	bind_result := binder.bind(module, file_path, allocator)

	// Pre-resolve relative imports from within the package
	// Parse each relative import target, extract its exports, build import_types
	import_types := make(map[binder.Symbol_ID]checker.Type_ID, 16, allocator)
	// Use shared registry for builtins — sub_registry caused Type_ID mismatch
	builtins := checker.init_builtins(registry)

	mod_scope := binder.result_get_scope(&bind_result, bind_result.module_scope)

	// Track already-parsed submodules to avoid cycles
	parsed_subs := make(map[string]bool, 16, allocator)
	parsed_subs[file_path] = true // mark self

	// Track sub-module exports for star import propagation
	sub_exports := make(map[string]Module_Exports, 8, allocator)

	// Recursively resolve relative imports within the package
	_resolve_pkg_imports(
		&bind_result, mod_scope, pkg_root, &import_types,
		bridge, registry, &builtins, &parsed_subs, &sub_exports, allocator, 0, res_ctx,
	)

	// Resolve absolute imports (stdlib + site-packages) when context available
	if res_ctx != nil && mod_scope != nil {
		_resolve_absolute_imports(&bind_result, mod_scope, &import_types, registry, res_ctx, allocator)
	}

	// Flow analysis on main file
	flow_result := flow.analyze(module, &bind_result, file_path, allocator)

	// Type check main file with resolved intra-package imports (shared registry)
	res := checker.Import_Resolution{
		registry     = registry,
		builtins     = &builtins,
		import_types = import_types,
	}
	check_result := checker.check(
		module, &bind_result, &flow_result, file_path, allocator, &res,
	)

	// Extract exports from module scope
	exports.types = make(map[string]checker.Type_ID, 16, allocator)
	if mod_scope == nil { return exports, true }

	for name, sym_id in mod_scope.symbols {
		if type_id, has := check_result.symbol_types[sym_id]; has {
			if type_id != checker.TYPE_UNKNOWN {
				exports.types[name] = type_id
			} else {
				// Fall back to TYPE_ANY for unresolved exports (complex stub types)
				// Prevents T007 false positives on valid module attributes
				exports.types[name] = checker.TYPE_ANY
			}
		}
	}

	// Propagate star imports: "from .sub import *" merges sub's exports
	for imp in bind_result.imports {
		if !imp.is_star { continue }
		if imp.level == 0 { continue } // only relative star imports

		sub_file := _resolve_relative_import(pkg_root, imp.module_name, allocator)
		if len(sub_file) == 0 { continue }

		if star_exp, has := sub_exports[sub_file]; has {
			for name, type_id in star_exp.types {
				if name not_in exports.types {
					exports.types[name] = type_id
				}
			}
		}
	}

	return exports, true
}

// Resolve absolute imports (stdlib + site-packages) for a parsed module.
// Wires resolved types into import_types so __init__ bodies can access them.
@(private = "file")
_resolve_absolute_imports :: proc(
	bind_result: ^binder.Bind_Result,
	mod_scope: ^binder.Scope,
	import_types: ^map[binder.Symbol_ID]checker.Type_ID,
	registry: ^checker.Type_Registry,
	res_ctx: ^Resolution_Context,
	allocator: mem.Allocator,
) {
	for imp in bind_result.imports {
		if imp.level > 0 { continue }
		if imp.module_name == "typing" || imp.module_name == "typing_extensions" { continue }

		target_exports: Module_Exports
		has_exports := false

		// Try stdlib stubs
		if len(res_ctx.stubs_dir) > 0 && platform.is_stdlib_module(imp.module_name) {
			stdlib_exp, stdlib_ok := resolve_from_stdlib_stubs(imp.module_name, res_ctx)
			if stdlib_ok {
				target_exports = stdlib_exp
				has_exports = true
			}
		}

		// Try site-packages
		if !has_exports && len(res_ctx.site_packages_dirs) > 0 {
			sp_exp, sp_ok := resolve_from_site_packages(imp.module_name, res_ctx)
			if sp_ok {
				target_exports = sp_exp
				has_exports = true
			}
		}

		if !has_exports { continue }

		if len(imp.names) == 0 && !imp.is_star {
			// "import X" → Module_Type
			top := imp.module_name
			for j := 0; j < len(top); j += 1 {
				if top[j] == '.' { top = top[:j]; break }
			}
			if sym_id, ok := mod_scope.symbols[top]; ok {
				mod_type_id := checker.register_type(registry, checker.Module_Type{
					name    = imp.module_name,
					exports = target_exports.types,
				})
				import_types[sym_id] = mod_type_id
			}
		} else if !imp.is_star {
			// "from X import Y, Z"
			for imp_name in imp.names {
				local := imp_name.alias if len(imp_name.alias) > 0 else imp_name.name
				if sym_id, ok := mod_scope.symbols[local]; ok {
					if type_id, found := target_exports.types[imp_name.name]; found {
						import_types[sym_id] = type_id
					}
				}
			}
		}
	}
}

// Recursively resolve relative imports for a package file.
// Parses each sub-module, extracts types, wires into import_types.
// Max depth prevents runaway recursion in deeply nested packages.
MAX_PKG_DEPTH :: 3

@(private = "file")
_resolve_pkg_imports :: proc(
	bind_result: ^binder.Bind_Result,
	mod_scope: ^binder.Scope,
	pkg_root: string,
	import_types: ^map[binder.Symbol_ID]checker.Type_ID,
	bridge: ^parser.Bridge,
	registry: ^checker.Type_Registry,
	builtins: ^checker.Builtin_Names,
	parsed_subs: ^map[string]bool,
	sub_exports: ^map[string]Module_Exports,
	allocator: mem.Allocator,
	depth: int,
	res_ctx: ^Resolution_Context = nil,
) {
	if depth >= MAX_PKG_DEPTH { return }
	if mod_scope == nil { return }

	for imp in bind_result.imports {
		if imp.level == 0 { continue } // skip absolute imports

		// Bare "from . import X" — skip for now (sub-module as namespace)
		// These would need Module_Type wrapping and separate resolution.
		if len(imp.module_name) == 0 { continue }

		// Resolve relative module to file
		sub_file := _resolve_relative_import(pkg_root, imp.module_name, allocator)
		if len(sub_file) == 0 { continue }
		if sub_file in parsed_subs { continue }
		parsed_subs[sub_file] = true

		// Parse submodule using SHARED registry
		sub_module, sub_err := parser.bridge_parse(bridge, sub_file, allocator)
		if sub_err != nil { continue }

		sub_bind := binder.bind(sub_module, sub_file, allocator)

		// Recursively resolve THIS sub-module's relative imports
		sub_pkg_root := _parent_dir(sub_file)
		sub_scope := binder.result_get_scope(&sub_bind, sub_bind.module_scope)
		sub_import_types := make(map[binder.Symbol_ID]checker.Type_ID, 8, allocator)

		_resolve_pkg_imports(
			&sub_bind, sub_scope, sub_pkg_root, &sub_import_types,
			bridge, registry, builtins, parsed_subs, sub_exports, allocator, depth + 1, res_ctx,
		)

		// Resolve absolute imports (stdlib + site-packages) for this sub-module
		if res_ctx != nil && sub_scope != nil {
			_resolve_absolute_imports(&sub_bind, sub_scope, &sub_import_types, registry, res_ctx, allocator)
		}

		// Check sub-module with its resolved imports
		sub_flow := flow.analyze(sub_module, &sub_bind, sub_file, allocator)
		sub_res := checker.Import_Resolution{
			registry     = registry,
			builtins     = builtins,
			import_types = sub_import_types,
		}
		sub_check := checker.check(
			sub_module, &sub_bind, &sub_flow, sub_file, allocator, &sub_res,
		)

		// Build name→type map from sub scope and CACHE it
		sub_type_map := make(map[string]checker.Type_ID, 8, allocator)
		if sub_scope != nil {
			for name, sub_sym_id in sub_scope.symbols {
				if type_id, has := sub_check.symbol_types[sub_sym_id]; has {
					if type_id != checker.TYPE_UNKNOWN {
						sub_type_map[name] = type_id
					}
				}
			}
		}

		// Cache sub-module exports for star import propagation
		if sub_exports != nil {
			se: Module_Exports
			se.types = sub_type_map
			sub_exports[sub_file] = se
		}

		// Wire imported names into caller's import_types
		if len(imp.names) > 0 {
			for imp_name in imp.names {
				local := imp_name.alias if len(imp_name.alias) > 0 else imp_name.name
				if sym_id, has_sym := mod_scope.symbols[local]; has_sym {
					if type_id, has_type := sub_type_map[imp_name.name]; has_type {
						import_types[sym_id] = type_id
					}
				}
			}
		}
	}
}

// Get parent directory of a file path.
@(private = "file")
_parent_dir :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' { return path[:i] }
	}
	return "."
}

// Resolve a relative import to a file path within the package.
// "app" within /path/flask/ → /path/flask/app.py
@(private = "file")
_resolve_relative_import :: proc(pkg_root: string, module_name: string, allocator: mem.Allocator) -> string {
	// Convert dots to slashes
	buf := make([dynamic]u8, 0, len(module_name), allocator)
	for c in module_name {
		if c == '.' {
			append(&buf, '/')
		} else {
			append(&buf, u8(c))
		}
	}
	sub_path := string(buf[:])

	// Try as file
	py := strings.concatenate({pkg_root, "/", sub_path, ".py"}, allocator)
	if os.is_file(py) { return py }

	pyi := strings.concatenate({pkg_root, "/", sub_path, ".pyi"}, allocator)
	if os.is_file(pyi) { return pyi }

	// Try as package
	init_py := strings.concatenate({pkg_root, "/", sub_path, "/__init__.py"}, allocator)
	if os.is_file(init_py) { return init_py }

	return ""
}
