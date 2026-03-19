package modules

import "core:mem"

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

		// Fallback: resolve from package cache if not a project module
		if !has_exports && ctx.cache != nil && ctx.bridge != nil {
			pkg_exports, pkg_ok := resolve_from_package_cache(
				imp.module_name, ctx,
			)
			if pkg_ok {
				target_exports = pkg_exports
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

// ==================== Package Cache Resolution ====================

// Resolve a third-party module from the package cache.
// Lazily parses the package file and caches the result.
@(private = "file")
resolve_from_package_cache :: proc(
	module_name: string,
	ctx: ^Resolution_Context,
) -> (exports: Module_Exports, ok: bool) {
	// Check lazy cache first
	if cached, has := ctx.parsed_packages[module_name]; has {
		return cached, true
	}

	// Find the file in the cache
	file_path, found := resolve_package_file(module_name, ctx.cache, ctx.allocator)
	if !found { return {}, false }

	// Parse + extract types
	pkg_exports, extract_ok := extract_package_exports(
		file_path, module_name, ctx.bridge, ctx.registry, ctx.allocator,
	)
	if !extract_ok { return {}, false }

	// Cache for subsequent lookups
	ctx.parsed_packages[module_name] = pkg_exports

	// Also store in main exports map so collect_exports-style lookups work
	ctx.exports[module_name] = pkg_exports

	return pkg_exports, true
}
