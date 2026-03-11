package migration

import "core:mem"
import "core:strings"
import parser "mimir:parser"
import binder "mimir:binder"
import core "mimir:core"

Python_Version :: struct {
	major: int,
	minor: int,
}

Migration_Config :: struct {
	from_version: Python_Version,
	to_version:   Python_Version,
	ignore:       []string,
	select_only:  []string,
}

Migration_Context :: struct {
	module:      ^parser.Module,
	bind_result: ^binder.Bind_Result,
	file_path:   string,
	config:      ^Migration_Config,
	diagnostics: [dynamic]core.Diagnostic,
	allocator:   mem.Allocator,
}

Migration_Rule :: struct {
	code:       string,
	name:       string,
	min_target: Python_Version, // only fire if to_version >= this
	check:      proc(ctx: ^Migration_Context),
}

ALL_RULES := [?]Migration_Rule{
	{code = "MIG001", name = "union-syntax",            min_target = {3, 10}, check = check_union_syntax},
	{code = "MIG002", name = "optional-syntax",         min_target = {3, 10}, check = check_optional_syntax},
	{code = "MIG003", name = "builtin-generics",        min_target = {3, 9},  check = check_builtin_generics},
	{code = "MIG004", name = "builtin-type",            min_target = {3, 9},  check = check_builtin_type},
	{code = "MIG005", name = "isinstance-union",        min_target = {3, 10}, check = check_isinstance_union},
	{code = "MIG006", name = "ordered-dict",            min_target = {3, 7},  check = check_ordered_dict},
	{code = "MIG007", name = "collections-abc",         min_target = {3, 9},  check = check_collections_abc},
	{code = "MIG008", name = "match-case-candidate",    min_target = {3, 10}, check = check_match_case},
}

default_config :: proc() -> Migration_Config {
	return Migration_Config{
		from_version = {3, 8},
		to_version   = {3, 12},
	}
}

version_gte :: proc(a, b: Python_Version) -> bool {
	if a.major != b.major { return a.major > b.major }
	return a.minor >= b.minor
}

version_lt :: proc(a, b: Python_Version) -> bool {
	return !version_gte(a, b)
}

parse_version :: proc(s: string) -> (Python_Version, bool) {
	dot := strings.index_byte(s, '.')
	if dot < 0 { return {}, false }
	major_str := s[:dot]
	minor_str := s[dot+1:]
	major, major_ok := parse_int_simple(major_str)
	minor, minor_ok := parse_int_simple(minor_str)
	if !major_ok || !minor_ok { return {}, false }
	return Python_Version{major, minor}, true
}

parse_int_simple :: proc(s: string) -> (int, bool) {
	if len(s) == 0 { return 0, false }
	result := 0
	for c in s {
		if c < '0' || c > '9' { return 0, false }
		result = result * 10 + int(c - '0')
	}
	return result, true
}

is_rule_enabled :: proc(rule: ^Migration_Rule, config: ^Migration_Config) -> bool {
	// Version gating: only fire if target >= min_target AND from < min_target
	if !version_gte(config.to_version, rule.min_target) { return false }
	if version_gte(config.from_version, rule.min_target) { return false }

	// Code filtering
	if len(config.select_only) > 0 {
		for s in config.select_only {
			if s == rule.code { return true }
		}
		return false
	}
	for ig in config.ignore {
		if ig == rule.code { return false }
	}
	return true
}

run_all_rules :: proc(ctx: ^Migration_Context) {
	for &rule in ALL_RULES {
		if is_rule_enabled(&rule, ctx.config) {
			rule.check(ctx)
		}
	}
}

analyze_migration :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	file_path: string,
	config: ^Migration_Config,
	allocator: mem.Allocator,
) -> []core.Diagnostic {
	ctx := Migration_Context{
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
