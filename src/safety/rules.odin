package safety

Safety_Rule :: struct {
	code:  string,
	name:  string,
	check: proc(ctx: ^Safety_Context),
}

ALL_RULES := [?]Safety_Rule{
	{code = "SAF001", name = "exception-swallowed",          check = check_exception_swallowed},
	{code = "SAF002", name = "overly-broad-except",          check = check_overly_broad_except},
	{code = "SAF003", name = "import-side-effect",           check = check_import_side_effect},
	{code = "SAF004", name = "monkey-patch",                 check = check_monkey_patch},
	{code = "SAF005", name = "global-state-mutation",        check = check_global_state_mutation},
	{code = "SAF006", name = "regex-catastrophic-backtrack", check = check_regex_catastrophic},
	{code = "SAF007", name = "sensitive-log-data",           check = check_sensitive_log_data},
	{code = "SAF008", name = "expensive-log-format",         check = check_expensive_log_format},
	{code = "SAF009", name = "mutable-default-argument",     check = check_mutable_default},
	{code = "SAF011", name = "mutable-class-variable",       check = check_mutable_class_var},
	{code = "SAF012", name = "open-without-with",            check = check_open_without_with},
}

is_rule_enabled :: proc(code: string, config: ^Safety_Config) -> bool {
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

run_all_rules :: proc(ctx: ^Safety_Context) {
	for &rule in ALL_RULES {
		if is_rule_enabled(rule.code, ctx.config) {
			rule.check(ctx)
		}
	}
}
