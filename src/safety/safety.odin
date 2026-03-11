package safety

import "core:mem"
import "core:strings"
import parser "mimir:parser"
import binder "mimir:binder"
import core "mimir:core"

Safety_Config :: struct {
	ignore:      []string,
	select_only: []string,
}

Safety_Context :: struct {
	module:      ^parser.Module,
	bind_result: ^binder.Bind_Result,
	file_path:   string,
	config:      ^Safety_Config,
	diagnostics: [dynamic]core.Diagnostic,
	allocator:   mem.Allocator,
}

default_config :: proc() -> Safety_Config {
	return Safety_Config{}
}

analyze_safety :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	file_path: string,
	config: ^Safety_Config,
	allocator: mem.Allocator,
) -> []core.Diagnostic {
	ctx := Safety_Context{
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

parse_code_list :: proc(input: string, allocator := context.allocator) -> []string {
	if input == "" { return nil }
	parts := strings.split(input, ",", allocator)
	result := make([dynamic]string, 0, len(parts), allocator)
	for p in parts {
		trimmed := strings.trim_space(p)
		if trimmed != "" {
			append(&result, trimmed)
		}
	}
	return result[:]
}
