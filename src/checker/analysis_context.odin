package checker

import "core:mem"

import parser "mimir:parser"
import binder "mimir:binder"

// ==================== Shared Analysis Context ====================
//
// Built once per file, shared across all post-inference analysis passes.
// Eliminates duplicate import detection (15+ passes were each scanning
// bind_result.imports independently).

Analysis_Pass_Context :: struct {
	module:       ^parser.Module,
	bind_result:  ^binder.Bind_Result,
	file_path:    string,
	allocator:    mem.Allocator,
	// Shared derived data (built once by build_analysis_pass_context):
	import_map:   map[string]string,  // local_name → module_name
	has_import:   map[string]bool,    // module_name → true
	// Optional type info (from checker — nil for non-type-aware passes):
	expr_types:   ^map[rawptr]Type_ID,
	registry:     ^Type_Registry,
}

// Build the shared context. Scans bind_result.imports once.
build_analysis_pass_context :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	file_path: string,
	allocator: mem.Allocator,
	expr_types: ^map[rawptr]Type_ID = nil,
	registry: ^Type_Registry = nil,
) -> Analysis_Pass_Context {
	ctx: Analysis_Pass_Context
	ctx.module = module
	ctx.bind_result = bind_result
	ctx.file_path = file_path
	ctx.allocator = allocator
	ctx.expr_types = expr_types
	ctx.registry = registry
	ctx.import_map = make(map[string]string, 16, allocator)
	ctx.has_import = make(map[string]bool, 16, allocator)

	for &imp in bind_result.imports {
		if len(imp.module_name) > 0 {
			ctx.has_import[imp.module_name] = true
		}
		if len(imp.names) > 0 {
			for name in imp.names {
				local := name.alias if len(name.alias) > 0 else name.name
				ctx.import_map[local] = imp.module_name
			}
		} else {
			local := imp.module_name
			for i := 0; i < len(local); i += 1 {
				if local[i] == '.' { local = local[:i]; break }
			}
			ctx.import_map[local] = imp.module_name
		}
	}

	return ctx
}
