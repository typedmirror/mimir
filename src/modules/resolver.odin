package modules

import "core:mem"
import "core:os"
import "core:strings"

import parser   "mimir:parser"
import binder   "mimir:binder"
import checker  "mimir:checker"
import platform "mimir:platform"

// ==================== Module Exports ====================

Module_Exports :: struct {
	types: map[string]checker.Type_ID, // exported name → type
}

// ==================== Resolution Context ====================

Resolution_Context :: struct {
	exports:          map[string]Module_Exports, // qualified_name → exports
	registry:         ^checker.Type_Registry,
	allocator:        mem.Allocator,
	// Third-party package resolution (optional — nil if no cache)
	bridge:           ^parser.Bridge,
	cache:            ^platform.Cache,
	parsed_packages:  map[string]Module_Exports,  // lazy cache: module_name → exports
	// Stdlib stub resolution (optional — "" if stubs not available)
	stubs_dir:        string,                      // ~/.mimir/stubs
	parsed_stdlib:    map[string]Module_Exports,   // lazy cache: module_name → exports
	// System site-packages resolution (optional — nil if not discovered)
	site_packages_dirs:   [dynamic]string,              // discovered site-packages paths
	parsed_site_packages: map[string]Module_Exports,    // lazy cache: module_name → exports
}

init_resolution_context :: proc(
	registry: ^checker.Type_Registry,
	allocator: mem.Allocator,
) -> Resolution_Context {
	ctx: Resolution_Context
	ctx.registry = registry
	ctx.allocator = allocator
	ctx.exports = make(map[string]Module_Exports, 16, allocator)
	return ctx
}

// ==================== Export Collection ====================

// After checking a module, collect its module-scope symbol types as exports
collect_exports :: proc(
	info: ^Module_Info,
	check_result: ^checker.Check_Result,
	ctx: ^Resolution_Context,
) {
	exports: Module_Exports
	exports.types = make(map[string]checker.Type_ID, 16, ctx.allocator)

	// Walk module-scope symbols
	mod_scope := binder.result_get_scope(&info.bind_result, info.bind_result.module_scope)
	if mod_scope == nil { return }

	for name, sym_id in mod_scope.symbols {
		if type_id, ok := check_result.symbol_types[sym_id]; ok {
			if type_id != checker.TYPE_UNKNOWN {
				exports.types[name] = type_id
			}
		}
	}

	// Propagate star imports: "from .B import *" merges B's exports into this module
	n_edges := min(len(info.bind_result.imports), len(info.imports))
	for i := 0; i < n_edges; i += 1 {
		edge := info.imports[i]
		if !edge.is_star { continue }
		if star_exports, has := ctx.exports[edge.target_module]; has {
			for name, type_id in star_exports.types {
				// Don't overwrite explicitly defined exports
				if name not_in exports.types {
					exports.types[name] = type_id
				}
			}
		}
	}

	ctx.exports[info.qualified_name] = exports
}

// ==================== Import Resolution ====================

// Resolve imports for a module, returning a map of local symbol_id → type
resolve_imports :: proc(
	info: ^Module_Info,
	ctx: ^Resolution_Context,
	vreg: ^checker.Virtual_Registry = nil,
) -> map[binder.Symbol_ID]checker.Type_ID {
	result := make(map[binder.Symbol_ID]checker.Type_ID, 16, ctx.allocator)

	mod_scope := binder.result_get_scope(&info.bind_result, info.bind_result.module_scope)
	if mod_scope == nil { return result }

	// Resolve virtual module imports (mimir.* ecosystem stubs)
	if vreg != nil {
		virtual := checker.resolve_virtual_imports(vreg, &info.bind_result, ctx.registry)
		for sym_id, type_id in virtual {
			result[sym_id] = type_id
		}
	}

	// Walk import records and corresponding import edges in parallel
	n_imports := min(len(info.bind_result.imports), len(info.imports))

	for i := 0; i < n_imports; i += 1 {
		imp := info.bind_result.imports[i]
		edge := info.imports[i]

		// Skip virtual modules — already resolved above
		if vreg != nil && checker.is_virtual_module(vreg, imp.module_name) {
			continue
		}

		// Look up target module's exports
		target_exports, has_exports := ctx.exports[edge.target_module]

		// Fallback 1: resolve stdlib modules from typeshed stubs
		// Skip typing/typing_extensions — handled by binder's typing_names mechanism
		if !has_exports && len(ctx.stubs_dir) > 0 && platform.is_stdlib_module(imp.module_name) &&
		   imp.module_name != "typing" && imp.module_name != "typing_extensions" {
			stdlib_exports, stdlib_ok := resolve_from_stdlib_stubs(imp.module_name, ctx)
			if stdlib_ok {
				target_exports = stdlib_exports
				has_exports = true
			}
		}

		// Fallback 2: resolve from package cache if not a project module
		if !has_exports && ctx.cache != nil && ctx.bridge != nil {
			pkg_exports, pkg_ok := resolve_from_package_cache(
				imp.module_name, ctx,
			)
			if pkg_ok {
				target_exports = pkg_exports
				has_exports = true
			}
		}

		// Fallback 3: resolve from system site-packages
		if !has_exports && len(ctx.site_packages_dirs) > 0 {
			sp_exports, sp_ok := resolve_from_site_packages(imp.module_name, ctx)
			if sp_ok {
				target_exports = sp_exports
				has_exports = true
			}
		}

		if !has_exports { continue }

		if edge.is_whole {
			// "import X" — create a Module_Type with X's exports
			// Find the symbol for the imported module name
			local_name := imp.module_name
			// For "import os.path", binder uses first component "os"
			// Find the dot and truncate
			for j := 0; j < len(local_name); j += 1 {
				if local_name[j] == '.' {
					local_name = local_name[:j]
					break
				}
			}

			if sym_id, ok := mod_scope.symbols[local_name]; ok {
				module_type_id := checker.register_type(ctx.registry, checker.Module_Type{
					name    = edge.target_module,
					exports = target_exports.types,
				})
				result[sym_id] = module_type_id
			}
		} else if !edge.is_star {
			// "from X import Y, Z" — look up each name in exports
			for imp_name in imp.names {
				local_name := imp_name.alias if len(imp_name.alias) > 0 else imp_name.name

				if sym_id, ok := mod_scope.symbols[local_name]; ok {
					if type_id, found := target_exports.types[imp_name.name]; found {
						result[sym_id] = type_id
					}
				}
			}
		}
		// Star imports: skip for now (binder doesn't create individual symbols)
	}

	return result
}

// ==================== Stdlib Stub Resolution ====================

// Resolve a stdlib module from typeshed .pyi stubs.
// Lazily parses the stub file and caches the result.
// Also checks/writes disk cache for cross-session persistence.
@(private = "file")
resolve_from_stdlib_stubs :: proc(
	module_name: string,
	ctx: ^Resolution_Context,
) -> (exports: Module_Exports, ok: bool) {
	// Check in-memory lazy cache first
	if cached, has := ctx.parsed_stdlib[module_name]; has {
		return cached, true
	}

	// Check disk cache
	cache_dir := _stub_cache_dir(ctx)
	if len(cache_dir) > 0 {
		cached_path, cached_found := read_stub_cache(module_name, cache_dir, "stdlib", ctx.allocator)
		if cached_found {
			// Parse the cached .pyi instead of the full stub
			stub_exports, extract_ok := extract_package_exports(
				cached_path, module_name, ctx.bridge, ctx.registry, ctx.allocator,
			)
			if extract_ok {
				_cache_stdlib(ctx, module_name, stub_exports)
				return stub_exports, true
			}
		}
	}

	// Find the stub file
	file_path, found := platform.resolve_stdlib_stub(module_name, ctx.stubs_dir, ctx.allocator)
	if !found { return {}, false }

	// Parse + extract types through existing pipeline
	stub_exports, extract_ok := extract_package_exports(
		file_path, module_name, ctx.bridge, ctx.registry, ctx.allocator,
	)
	if !extract_ok { return {}, false }

	// Write to disk cache for next session
	if len(cache_dir) > 0 {
		write_stub_cache(module_name, &stub_exports, ctx.registry, cache_dir, "stdlib", ctx.allocator)
	}

	_cache_stdlib(ctx, module_name, stub_exports)
	return stub_exports, true
}

@(private = "file")
_cache_stdlib :: proc(ctx: ^Resolution_Context, module_name: string, exports: Module_Exports) {
	if ctx.parsed_stdlib == nil {
		ctx.parsed_stdlib = make(map[string]Module_Exports, 16, ctx.allocator)
	}
	ctx.parsed_stdlib[module_name] = exports
	ctx.exports[module_name] = exports
}

@(private = "file")
_stub_cache_dir :: proc(ctx: ^Resolution_Context) -> string {
	if len(ctx.stubs_dir) == 0 { return "" }
	return strings.concatenate({ctx.stubs_dir, "/cache"}, ctx.allocator)
}

// ==================== Package Cache Resolution ====================

// Resolve a third-party module from the package cache.
// Lazily parses the package file and caches the result.
// Also checks/writes disk cache for cross-session persistence.
@(private = "file")
resolve_from_package_cache :: proc(
	module_name: string,
	ctx: ^Resolution_Context,
) -> (exports: Module_Exports, ok: bool) {
	// Check in-memory lazy cache first
	if cached, has := ctx.parsed_packages[module_name]; has {
		return cached, true
	}

	// Check disk cache (use content hash as key if available)
	cache_dir := _stub_cache_dir(ctx)
	cache_key := "pkg"
	if len(cache_dir) > 0 {
		cached_path, cached_found := read_stub_cache(module_name, cache_dir, cache_key, ctx.allocator)
		if cached_found {
			pkg_exports, extract_ok := extract_package_exports(
				cached_path, module_name, ctx.bridge, ctx.registry, ctx.allocator,
			)
			if extract_ok {
				ctx.parsed_packages[module_name] = pkg_exports
				ctx.exports[module_name] = pkg_exports
				return pkg_exports, true
			}
		}
	}

	// Find the file in the cache
	file_path, found := resolve_package_file(module_name, ctx.cache, ctx.allocator)
	if !found { return {}, false }

	// Parse + extract types
	pkg_exports, extract_ok := extract_package_exports(
		file_path, module_name, ctx.bridge, ctx.registry, ctx.allocator,
	)
	if !extract_ok { return {}, false }

	// Write to disk cache for next session
	if len(cache_dir) > 0 {
		write_stub_cache(module_name, &pkg_exports, ctx.registry, cache_dir, cache_key, ctx.allocator)
	}

	// Cache for subsequent lookups
	ctx.parsed_packages[module_name] = pkg_exports
	ctx.exports[module_name] = pkg_exports

	return pkg_exports, true
}

// ==================== Site-Packages Resolution ====================

// Discover Python site-packages directories on the system.
// Checks: VIRTUAL_ENV, common system paths, user site-packages.
// No Python dependency — walks known filesystem paths.
discover_site_packages :: proc(allocator: mem.Allocator) -> [dynamic]string {
	dirs := make([dynamic]string, 0, 4, allocator)

	// 1. Active virtualenv (highest priority)
	venv, venv_found := os.lookup_env("VIRTUAL_ENV", allocator)
	if venv_found && len(venv) > 0 {
		_glob_site_packages(venv, "lib", &dirs, allocator)
	}

	// 2. User site-packages
	home, home_err := os.user_home_dir(allocator)
	if home_err == nil {
		// macOS: ~/Library/Python/*/lib/python/site-packages/
		mac_base := strings.concatenate({home, "/Library/Python"}, allocator)
		if os.is_directory(mac_base) {
			entries, err := os.read_all_directory_by_path(mac_base, allocator)
			if err == nil {
				for entry in entries {
					if entry.type == .Directory {
						sp := strings.concatenate({mac_base, "/", entry.name, "/lib/python/site-packages"}, allocator)
						if os.is_directory(sp) {
							append(&dirs, sp)
						}
					}
				}
			}
		}

		// Linux: ~/.local/lib/python*/site-packages/
		linux_base := strings.concatenate({home, "/.local/lib"}, allocator)
		if os.is_directory(linux_base) {
			_glob_site_packages(linux_base, "", &dirs, allocator)
		}
	}

	// 3. System site-packages (common locations)
	SYSTEM_BASES :: [?]string{
		"/opt/homebrew/lib",                  // macOS Homebrew ARM
		"/usr/local/lib",                     // macOS/Linux local
		"/usr/lib",                           // Linux system
		"/Library/Frameworks/Python.framework/Versions", // macOS framework
	}
	for base in SYSTEM_BASES {
		if os.is_directory(base) {
			_glob_site_packages(base, "", &dirs, allocator)
		}
	}

	return dirs
}

// Find python*/site-packages or python*/lib/python/site-packages in a directory.
@(private = "file")
_glob_site_packages :: proc(base: string, subdir: string, dirs: ^[dynamic]string, allocator: mem.Allocator) {
	search_dir := base
	if len(subdir) > 0 {
		search_dir = strings.concatenate({base, "/", subdir}, allocator)
	}
	if !os.is_directory(search_dir) { return }

	entries, err := os.read_all_directory_by_path(search_dir, allocator)
	if err != nil { return }

	for entry in entries {
		if entry.type != .Directory { continue }
		if !strings.has_prefix(entry.name, "python") { continue }

		// Direct: <search_dir>/python3.x/site-packages/
		sp := strings.concatenate({search_dir, "/", entry.name, "/site-packages"}, allocator)
		if os.is_directory(sp) {
			// Check if already in list (dedup)
			found := false
			for existing in dirs {
				if existing == sp { found = true; break }
			}
			if !found { append(dirs, sp) }
			continue
		}

		// Nested: <search_dir>/python3.x/lib/python/site-packages/ (venv layout)
		sp2 := strings.concatenate({search_dir, "/", entry.name, "/lib/python/site-packages"}, allocator)
		if os.is_directory(sp2) {
			found := false
			for existing in dirs {
				if existing == sp2 { found = true; break }
			}
			if !found { append(dirs, sp2) }
		}
	}
}

// Resolve a module from system site-packages.
// Same pattern as resolve_from_package_cache: lazy parse + disk cache.
@(private = "file")
resolve_from_site_packages :: proc(
	module_name: string,
	ctx: ^Resolution_Context,
) -> (exports: Module_Exports, ok: bool) {
	// Check in-memory lazy cache first
	if cached, has := ctx.parsed_site_packages[module_name]; has {
		return cached, true
	}

	// Check disk cache
	cache_dir := _stub_cache_dir(ctx)
	cache_key := "site"
	if len(cache_dir) > 0 {
		cached_path, cached_found := read_stub_cache(module_name, cache_dir, cache_key, ctx.allocator)
		if cached_found {
			sp_exports, extract_ok := extract_package_exports(
				cached_path, module_name, ctx.bridge, ctx.registry, ctx.allocator,
			)
			if extract_ok {
				_cache_site_packages(ctx, module_name, sp_exports)
				return sp_exports, true
			}
		}
	}

	// Search each site-packages directory for the module
	file_path := ""
	for sp_dir in ctx.site_packages_dirs {
		found_path, found := find_module_in_site_packages(module_name, sp_dir, ctx.allocator)
		if found {
			file_path = found_path
			break
		}
	}
	if len(file_path) == 0 { return {}, false }

	// Parse + extract types through existing pipeline
	sp_exports, extract_ok := extract_package_exports(
		file_path, module_name, ctx.bridge, ctx.registry, ctx.allocator,
	)
	if !extract_ok { return {}, false }

	// Write to disk cache for next session
	if len(cache_dir) > 0 {
		write_stub_cache(module_name, &sp_exports, ctx.registry, cache_dir, cache_key, ctx.allocator)
	}

	_cache_site_packages(ctx, module_name, sp_exports)
	return sp_exports, true
}

@(private = "file")
_cache_site_packages :: proc(ctx: ^Resolution_Context, module_name: string, exports: Module_Exports) {
	if ctx.parsed_site_packages == nil {
		ctx.parsed_site_packages = make(map[string]Module_Exports, 16, ctx.allocator)
	}
	ctx.parsed_site_packages[module_name] = exports
	ctx.exports[module_name] = exports
}

// Find a module in a site-packages directory.
// Handles both packages (dir/__init__.py[i]) and single-file modules (module.py[i]).
// Handles dotted modules: "httpcore._sync" → httpcore/_sync.py[i]
find_module_in_site_packages :: proc(
	module_name: string,
	sp_dir: string,
	allocator: mem.Allocator,
) -> (file_path: string, found: bool) {
	// Split on first dot: "httpcore._sync" → top="httpcore", sub="_sync"
	top := module_name
	sub_path := ""
	for i := 0; i < len(module_name); i += 1 {
		if module_name[i] == '.' {
			top = module_name[:i]
			sub_path = module_name[i+1:]
			break
		}
	}

	if len(sub_path) == 0 {
		// Simple module: httpcore/__init__.pyi, httpcore/__init__.py, httpcore.pyi, httpcore.py
		pyi_init := strings.concatenate({sp_dir, "/", top, "/__init__.pyi"}, allocator)
		if os.is_file(pyi_init) { return pyi_init, true }

		py_init := strings.concatenate({sp_dir, "/", top, "/__init__.py"}, allocator)
		if os.is_file(py_init) { return py_init, true }

		pyi := strings.concatenate({sp_dir, "/", top, ".pyi"}, allocator)
		if os.is_file(pyi) { return pyi, true }

		py := strings.concatenate({sp_dir, "/", top, ".py"}, allocator)
		if os.is_file(py) { return py, true }

		return "", false
	}

	// Dotted module: convert sub dots to slashes
	buf := make([dynamic]u8, 0, len(sub_path), allocator)
	for i := 0; i < len(sub_path); i += 1 {
		if sub_path[i] == '.' {
			append(&buf, '/')
		} else {
			append(&buf, sub_path[i])
		}
	}
	sub_file := string(buf[:])

	// Try: top/sub.pyi, top/sub.py
	pyi := strings.concatenate({sp_dir, "/", top, "/", sub_file, ".pyi"}, allocator)
	if os.is_file(pyi) { return pyi, true }

	py := strings.concatenate({sp_dir, "/", top, "/", sub_file, ".py"}, allocator)
	if os.is_file(py) { return py, true }

	// Try as package: top/sub/__init__.pyi, top/sub/__init__.py
	pyi_init := strings.concatenate({sp_dir, "/", top, "/", sub_file, "/__init__.pyi"}, allocator)
	if os.is_file(pyi_init) { return pyi_init, true }

	py_init := strings.concatenate({sp_dir, "/", top, "/", sub_file, "/__init__.py"}, allocator)
	if os.is_file(py_init) { return py_init, true }

	return "", false
}
