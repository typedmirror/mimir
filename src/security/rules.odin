package security

import "core:strings"

Security_Rule :: struct {
	code:  string,
	name:  string,
	check: proc(ctx: ^Security_Context),
}

ALL_RULES := [?]Security_Rule{
	{code = "SEC001", name = "weak-hash",              check = check_weak_hash},
	{code = "SEC002", name = "insecure-random",        check = check_insecure_random},
	{code = "SEC003", name = "timing-attack",          check = check_timing_attack},
	{code = "SEC004", name = "hardcoded-secret",       check = check_hardcoded_secret},
	{code = "SEC005", name = "embedded-credentials",   check = check_embedded_credentials},
	{code = "SEC006", name = "eval-exec",              check = check_eval_exec},
	{code = "SEC007", name = "unsafe-deserialization",  check = check_unsafe_deserialization},
	{code = "SEC008", name = "shell-injection",        check = check_shell_injection},
	{code = "SEC009", name = "typosquat-suspect",      check = check_typosquat},
}

is_rule_enabled :: proc(code: string, config: ^Security_Config) -> bool {
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

run_all_rules :: proc(ctx: ^Security_Context) {
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
