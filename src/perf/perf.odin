package perf

import "core:mem"
import "core:strings"
import parser "mimir:parser"
import binder "mimir:binder"
import core "mimir:core"

Perf_Config :: struct {
	ignore:      []string,
	select_only: []string,
}

Perf_Context :: struct {
	source:        string,
	lines:         []string,
	module:        ^parser.Module,
	bind_result:   ^binder.Bind_Result,
	file_path:     string,
	config:        ^Perf_Config,
	diagnostics:   [dynamic]core.Diagnostic,
	import_map:    map[string]string,
	allocator:     mem.Allocator,
	current_scope: []parser.Stmt,  // innermost function body for scoped checks
}

default_config :: proc() -> Perf_Config {
	return Perf_Config{}
}

analyze_performance :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	source: string,
	file_path: string,
	config: ^Perf_Config,
	allocator: mem.Allocator,
) -> []core.Diagnostic {
	ctx := Perf_Context{
		source      = source,
		lines       = strings.split(source, "\n", allocator),
		module      = module,
		bind_result = bind_result,
		file_path   = file_path,
		config      = config,
		diagnostics = make([dynamic]core.Diagnostic, 0, 16, allocator),
		import_map  = make(map[string]string, 16, allocator),
		allocator   = allocator,
	}

	build_import_map(&ctx)
	run_all_rules(&ctx)

	return ctx.diagnostics[:]
}

build_import_map :: proc(ctx: ^Perf_Context) {
	visitor := core.AST_Visitor{
		visit_stmt = proc(stmt: parser.Stmt, raw_ctx: rawptr) {
			ctx := cast(^Perf_Context)raw_ctx
			#partial switch s in stmt {
			case ^parser.Import_Stmt:
				for alias in s.names {
					local := alias.asname if len(alias.asname) > 0 else alias.name
					if len(alias.asname) == 0 {
						for i := 0; i < len(local); i += 1 {
							if local[i] == '.' {
								local = local[:i]
								break
							}
						}
					}
					ctx.import_map[local] = alias.name
				}
			case ^parser.Import_From:
				if s.level > 0 { return }
				for alias in s.names {
					if alias.name == "*" { continue }
					local := alias.asname if len(alias.asname) > 0 else alias.name
					ctx.import_map[local] = s.module
				}
			}
		},
		ctx = rawptr(ctx),
	}
	core.walk_all_stmts(&visitor, ctx.module.body)
}
