package perf

import "core:strings"

Perf_Rule :: struct {
	code:  string,
	name:  string,
	check: proc(ctx: ^Perf_Context),
}

ALL_RULES := [?]Perf_Rule{
	{code = "PERF001", name = "string-concat-in-loop",      check = check_string_concat_in_loop},
	{code = "PERF002", name = "unnecessary-list-comp",       check = check_unnecessary_list_comp},
	{code = "PERF003", name = "open-read-full-file",         check = check_open_read},
	{code = "PERF004", name = "unhashable-lru-cache-param",  check = check_unhashable_lru_cache},
}

is_rule_enabled :: proc(code: string, config: ^Perf_Config) -> bool {
	if len(config.select_only) > 0 {
		for s in config.select_only {
			if s == code { return true }
		}
		return false
	}
	for ig in config.ignore {
		if ig == code { return false }
	}
	return true
}

run_all_rules :: proc(ctx: ^Perf_Context) {
	for &rule in ALL_RULES {
		if is_rule_enabled(rule.code, ctx.config) {
			rule.check(ctx)
		}
	}
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
