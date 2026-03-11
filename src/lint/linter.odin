package lint

import "core:mem"
import "core:strings"
import parser "mimir:parser"
import binder "mimir:binder"
import core "mimir:core"

Lint_Config :: struct {
	line_length: int,       // default 88
	ignore:      []string,  // codes to skip, e.g. ["C001", "S001"]
	select_only: []string,  // codes to run (empty = all)
}

Lint_Context :: struct {
	source:      string,
	lines:       []string,
	module:      ^parser.Module,
	bind_result: ^binder.Bind_Result,
	file_path:   string,
	config:      ^Lint_Config,
	diagnostics: [dynamic]core.Diagnostic,
	allocator:   mem.Allocator,
}

default_config :: proc() -> Lint_Config {
	return Lint_Config{
		line_length = 88,
	}
}

lint_file :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	source: string,
	file_path: string,
	config: ^Lint_Config,
	allocator: mem.Allocator,
) -> []core.Diagnostic {
	ctx := Lint_Context{
		source      = source,
		lines       = strings.split(source, "\n", allocator),
		module      = module,
		bind_result = bind_result,
		file_path   = file_path,
		config      = config,
		diagnostics = make([dynamic]core.Diagnostic, 0, 16, allocator),
		allocator   = allocator,
	}

	run_all_rules(&ctx)

	return ctx.diagnostics[:]
}
