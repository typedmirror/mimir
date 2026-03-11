package lint

import "core:strings"

Lint_Rule :: struct {
	code:  string,
	name:  string,
	check: proc(ctx: ^Lint_Context),
}

ALL_RULES := [?]Lint_Rule{
	{code = "L001", name = "unused-import",            check = check_unused_import},
	{code = "L002", name = "unused-variable",          check = check_unused_variable},
	{code = "L003", name = "mutable-default-arg",      check = check_mutable_default},
	{code = "L004", name = "fstring-no-placeholders",  check = check_fstring_no_placeholders},
	{code = "L005", name = "bare-except",              check = check_bare_except},
	{code = "L006", name = "assert-tuple",             check = check_assert_tuple},
	{code = "C001", name = "naming-convention",        check = check_naming_convention},
	{code = "C002", name = "star-import",              check = check_star_import},
	{code = "S001", name = "line-too-long",            check = check_line_too_long},
}

is_rule_enabled :: proc(code: string, config: ^Lint_Config) -> bool {
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

run_all_rules :: proc(ctx: ^Lint_Context) {
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
