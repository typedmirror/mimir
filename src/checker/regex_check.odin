package checker

import "core:fmt"
import "core:mem"
import "core:strings"

import parser "mimir:parser"
import binder "mimir:binder"
import core   "mimir:core"

// ==================== Regex Analysis ====================
//
// Post-inference analysis pass for regex group validation.
// Tracks re.compile/re.match/re.search calls with string literal patterns,
// parses patterns to extract group info, then validates .group() calls.
//
// Diagnostics:
//   REG001 — Invalid group reference (numeric out-of-range)
//   REG002 — Invalid named group reference (with "did you mean?" suggestion)

Regex_Group_Info :: struct {
	num_groups:   int,
	named_groups: []string,
	pattern_loc:  core.Location,
}

Regex_Check_Context :: struct {
	file_path:      string,
	diagnostics:    ^[dynamic]core.Diagnostic,
	pattern_groups: map[string]Regex_Group_Info,  // compiled pattern var → group info
	match_groups:   map[string]Regex_Group_Info,   // match var → group info
	allocator:      mem.Allocator,
}

// Entry point — called from checker.odin after type checking.
// Accepts shared Analysis_Pass_Context for import detection.
analyze_regex :: proc(
	actx: ^Analysis_Pass_Context,
	diagnostics: ^[dynamic]core.Diagnostic,
) {
	if !actx.has_import["re"] { return }
	module := actx.module
	file_path := actx.file_path
	allocator := actx.allocator

	// Analyze each function body independently (variable names are function-scoped)
	for stmt in module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			analyze_regex_in_body(s.body, file_path, diagnostics, allocator)
		case ^parser.Async_Func_Def:
			analyze_regex_in_body(s.body, file_path, diagnostics, allocator)
		}
	}
}

analyze_regex_in_body :: proc(
	body: []parser.Stmt,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	ctx := Regex_Check_Context{
		file_path      = file_path,
		diagnostics    = diagnostics,
		pattern_groups = make(map[string]Regex_Group_Info, 8, allocator),
		match_groups   = make(map[string]Regex_Group_Info, 8, allocator),
		allocator      = allocator,
	}

	// Pass 1: Collect regex patterns and match variables
	for stmt in body {
		collect_regex_assignments(&ctx, stmt)
	}

	// Skip pass 2 if no patterns found
	if len(ctx.match_groups) == 0 && len(ctx.pattern_groups) == 0 { return }

	// Pass 2: Validate .group() calls
	validate_visitor := core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			ctx := cast(^Regex_Check_Context)raw_ctx
			validate_group_call(ctx, expr)
		},
		ctx = rawptr(&ctx),
	}
	core.walk_all_stmts(&validate_visitor, body)
}

// ==================== Pass 1: Collection ====================

collect_regex_assignments :: proc(ctx: ^Regex_Check_Context, stmt: parser.Stmt) {
	#partial switch s in stmt {
	case ^parser.Assign:
		if len(s.targets) != 1 { return }
		name, is_name := s.targets[0].(^parser.Name_Expr)
		if !is_name { return }

		call, is_call := s.value.(^parser.Call_Expr)
		if !is_call { return }

		collect_from_call(ctx, name.id, call, s.loc)

	case ^parser.For_Stmt:
		// for m in re.finditer(r"...", text):
		target_name, is_name := s.target.(^parser.Name_Expr)
		if is_name {
			call, is_call := s.iter.(^parser.Call_Expr)
			if is_call && is_re_func_call(call, "finditer") {
				if len(call.args) >= 1 {
					pattern := get_pattern_string(call.args[0])
					if len(pattern) > 0 {
						info := parse_regex_groups(pattern, ctx.file_path, s.loc, ctx.allocator)
						ctx.match_groups[target_name.id] = info
					}
				}
			}
		}
		// Recurse into for body (but not nested functions)
		for sub in s.body { collect_regex_assignments(ctx, sub) }
		for sub in s.orelse { collect_regex_assignments(ctx, sub) }

	case ^parser.If_Stmt:
		for sub in s.body { collect_regex_assignments(ctx, sub) }
		for sub in s.orelse { collect_regex_assignments(ctx, sub) }

	case ^parser.While_Stmt:
		for sub in s.body { collect_regex_assignments(ctx, sub) }
		for sub in s.orelse { collect_regex_assignments(ctx, sub) }

	case ^parser.With_Stmt:
		for sub in s.body { collect_regex_assignments(ctx, sub) }

	case ^parser.Try_Stmt:
		for sub in s.body { collect_regex_assignments(ctx, sub) }
		for sub in s.orelse { collect_regex_assignments(ctx, sub) }
		for sub in s.finalbody { collect_regex_assignments(ctx, sub) }
		for &handler in s.handlers {
			for sub in handler.body { collect_regex_assignments(ctx, sub) }
		}

	// Do NOT recurse into nested Func_Def / Async_Func_Def — different scope
	}
}

collect_from_call :: proc(ctx: ^Regex_Check_Context, var_name: string, call: ^parser.Call_Expr, loc: parser.Src_Loc) {
	// re.compile(r"...") → pattern_groups
	if is_re_func_call(call, "compile") {
		if len(call.args) >= 1 {
			pattern := get_pattern_string(call.args[0])
			if len(pattern) > 0 {
				info := parse_regex_groups(pattern, ctx.file_path, loc, ctx.allocator)
				ctx.pattern_groups[var_name] = info
			}
		}
		return
	}

	// re.match/search/fullmatch(r"...", text) → match_groups
	RE_MATCH_FUNCS :: [?]string{"match", "search", "fullmatch"}
	for fn in RE_MATCH_FUNCS {
		if is_re_func_call(call, fn) {
			if len(call.args) >= 1 {
				pattern := get_pattern_string(call.args[0])
				if len(pattern) > 0 {
					info := parse_regex_groups(pattern, ctx.file_path, loc, ctx.allocator)
					ctx.match_groups[var_name] = info
				}
			}
			return
		}
	}

	// pattern.match/search/fullmatch(text) → look up pattern in pattern_groups
	attr, is_attr := call.func.(^parser.Attribute_Expr)
	if !is_attr { return }

	COMPILED_FUNCS :: [?]string{"match", "search", "fullmatch", "findall", "finditer"}
	is_compiled_method := false
	for fn in COMPILED_FUNCS {
		if attr.attr == fn { is_compiled_method = true; break }
	}
	if !is_compiled_method { return }

	base_name, is_base_name := attr.value.(^parser.Name_Expr)
	if !is_base_name { return }

	if info, ok := ctx.pattern_groups[base_name.id]; ok {
		// For findall/finditer, the variable is a list, not a match — skip
		if attr.attr == "findall" { return }
		if attr.attr == "finditer" {
			// Will be handled in For_Stmt collection — skip here
			return
		}
		ctx.match_groups[var_name] = info
	}
}

is_re_func_call :: proc(call: ^parser.Call_Expr, func_name: string) -> bool {
	attr, is_attr := call.func.(^parser.Attribute_Expr)
	if !is_attr { return false }
	base, is_name := attr.value.(^parser.Name_Expr)
	if !is_name || base.id != "re" { return false }
	return attr.attr == func_name
}

get_pattern_string :: proc(expr: parser.Expr) -> string {
	if expr == nil { return "" }
	if c, ok := expr.(^parser.Constant_Expr); ok {
		if s, s_ok := c.value.(string); s_ok {
			return s
		}
	}
	return ""
}

// ==================== Pass 2: Validation ====================

validate_group_call :: proc(ctx: ^Regex_Check_Context, expr: parser.Expr) {
	// Check m.group(N) / m.group("name")
	call, is_call := expr.(^parser.Call_Expr)
	if is_call {
		validate_group_method_call(ctx, call)
		return
	}

	// Check m[N] (subscript)
	sub, is_sub := expr.(^parser.Subscript_Expr)
	if is_sub {
		validate_subscript(ctx, sub)
	}
}

validate_group_method_call :: proc(ctx: ^Regex_Check_Context, call: ^parser.Call_Expr) {
	attr, is_attr := call.func.(^parser.Attribute_Expr)
	if !is_attr { return }
	if attr.attr != "group" { return }

	base_name, is_name := attr.value.(^parser.Name_Expr)
	if !is_name { return }

	info, ok := ctx.match_groups[base_name.id]
	if !ok { return }

	// .group() with no args = group(0), always valid
	if len(call.args) == 0 { return }

	arg := call.args[0]

	// Numeric group reference
	if c, c_ok := arg.(^parser.Constant_Expr); c_ok {
		if n, n_ok := c.value.(i64); n_ok {
			group_num := int(n)
			if group_num < 0 || group_num > info.num_groups {
				available := fmt.tprintf("%d capturing group%s", info.num_groups, "s" if info.num_groups != 1 else "")
				append(ctx.diagnostics, core.Diagnostic{
					severity = .Error,
					location = core.Location{
						file   = ctx.file_path,
						line   = int(call.loc.line),
						column = int(call.loc.col),
					},
					what = fmt.tprintf("invalid group reference %d, pattern has %s", group_num, available),
					why  = "group index exceeds the number of capturing groups in the regex pattern",
					fix  = fmt.tprintf("use group(0) through group(%d)", info.num_groups),
					code = "REG001",
				})
			}
			return
		}

		// Named group reference
		if name, s_ok := c.value.(string); s_ok {
			found := false
			for ng in info.named_groups {
				if ng == name { found = true; break }
			}
			if !found {
				suggestion := find_closest_group(name, info.named_groups)
				fix_msg: string
				if len(suggestion) > 0 {
					fix_msg = fmt.tprintf("did you mean \"%s\"?", suggestion)
				} else if len(info.named_groups) > 0 {
					fix_msg = fmt.tprintf("available named groups: %s", format_group_names(info.named_groups))
				} else {
					fix_msg = "this pattern has no named groups"
				}
				append(ctx.diagnostics, core.Diagnostic{
					severity = .Error,
					location = core.Location{
						file   = ctx.file_path,
						line   = int(call.loc.line),
						column = int(call.loc.col),
					},
					what = fmt.tprintf("no group named \"%s\" in pattern", name),
					why  = "the regex pattern does not define a group with this name",
					fix  = fix_msg,
					code = "REG002",
				})
			}
		}
	}
}

validate_subscript :: proc(ctx: ^Regex_Check_Context, sub: ^parser.Subscript_Expr) {
	base_name, is_name := sub.value.(^parser.Name_Expr)
	if !is_name { return }

	info, ok := ctx.match_groups[base_name.id]
	if !ok { return }

	if c, c_ok := sub.slice.(^parser.Constant_Expr); c_ok {
		if n, n_ok := c.value.(i64); n_ok {
			group_num := int(n)
			if group_num < 0 || group_num > info.num_groups {
				available := fmt.tprintf("%d capturing group%s", info.num_groups, "s" if info.num_groups != 1 else "")
				append(ctx.diagnostics, core.Diagnostic{
					severity = .Error,
					location = core.Location{
						file   = ctx.file_path,
						line   = int(sub.loc.line),
						column = int(sub.loc.col),
					},
					what = fmt.tprintf("invalid group reference %d, pattern has %s", group_num, available),
					why  = "group index exceeds the number of capturing groups in the regex pattern",
					fix  = fmt.tprintf("use index 0 through %d", info.num_groups),
					code = "REG001",
				})
			}
		}
	}
}

// ==================== Regex Pattern Parser ====================

parse_regex_groups :: proc(pattern: string, file_path: string, loc: parser.Src_Loc, allocator: mem.Allocator) -> Regex_Group_Info {
	num_groups := 0
	named_groups := make([dynamic]string, 0, 4, allocator)
	in_char_class := false
	i := 0

	for i < len(pattern) {
		c := pattern[i]

		// Skip escaped characters
		if c == '\\' {
			i += 2
			continue
		}

		// Character class — parens inside don't count
		if c == '[' {
			in_char_class = true
			i += 1
			continue
		}
		if c == ']' && in_char_class {
			in_char_class = false
			i += 1
			continue
		}
		if in_char_class {
			i += 1
			continue
		}

		// Opening paren
		if c == '(' {
			i += 1
			if i < len(pattern) && pattern[i] == '?' {
				// Non-capturing or special group
				i += 1
				if i < len(pattern) {
					next := pattern[i]
					if next == ':' || next == '=' || next == '!' {
						// (?:  (?=  (?!  — non-capturing
						i += 1
						continue
					}
					if next == '<' {
						i += 1
						if i < len(pattern) {
							if pattern[i] == '=' || pattern[i] == '!' {
								// (?<=  (?<!  — lookbehind, non-capturing
								i += 1
								continue
							}
						}
						// Not lookbehind — this is a named group (?P is handled below
						// Actually (?<name>...) is Python 3.x alternate syntax — not standard
						// Fall through as non-capturing
						continue
					}
					if next == 'P' {
						i += 1
						if i < len(pattern) && pattern[i] == '<' {
							// (?P<name>...) — named capturing group
							i += 1
							name_start := i
							for i < len(pattern) && pattern[i] != '>' {
								i += 1
							}
							if i > name_start {
								name := pattern[name_start:i]
								append(&named_groups, name)
							}
							num_groups += 1
							if i < len(pattern) { i += 1 } // skip >
							continue
						}
						if i < len(pattern) && pattern[i] == '=' {
							// (?P=name) — backreference, non-capturing
							i += 1
							continue
						}
					}
					if next == '#' {
						// (?#...) — comment, non-capturing
						for i < len(pattern) && pattern[i] != ')' {
							i += 1
						}
						if i < len(pattern) { i += 1 } // skip )
						continue
					}
					// Other (?... forms (flags etc.) — non-capturing
					continue
				}
			} else {
				// Plain ( — capturing group
				num_groups += 1
			}
			continue
		}

		i += 1
	}

	return Regex_Group_Info{
		num_groups   = num_groups,
		named_groups = named_groups[:],
		pattern_loc  = core.Location{
			file   = file_path,
			line   = int(loc.line),
			column = int(loc.col),
		},
	}
}

// ==================== Helpers ====================

find_closest_group :: proc(name: string, groups: []string) -> string {
	if len(groups) == 0 { return "" }

	// Simple matching: check prefix, suffix, or substring
	lower_name := strings.to_lower(name, context.temp_allocator)

	best := ""
	best_score := 0

	for g in groups {
		lower_g := strings.to_lower(g, context.temp_allocator)

		score := 0
		// Exact prefix match
		if strings.has_prefix(lower_g, lower_name) || strings.has_prefix(lower_name, lower_g) {
			score = 3
		}
		// Substring match
		if score == 0 && (strings.contains(lower_g, lower_name) || strings.contains(lower_name, lower_g)) {
			score = 2
		}
		// Same length, differ by 1-2 chars (simple edit distance approximation)
		if score == 0 && len(g) == len(name) {
			diffs := 0
			for j in 0..<len(g) {
				lg := lower_g[j]
				ln := lower_name[j]
				if lg != ln { diffs += 1 }
			}
			if diffs <= 2 { score = 3 - diffs }
		}

		if score > best_score {
			best_score = score
			best = g
		}
	}

	return best
}

format_group_names :: proc(groups: []string) -> string {
	if len(groups) == 0 { return "" }
	if len(groups) == 1 { return fmt.tprintf("\"%s\"", groups[0]) }

	b := strings.builder_make(context.temp_allocator)
	for g, i in groups {
		if i > 0 { strings.write_string(&b, ", ") }
		strings.write_string(&b, fmt.tprintf("\"%s\"", g))
	}
	return strings.to_string(b)
}
