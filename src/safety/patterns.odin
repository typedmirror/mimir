package safety

import "core:fmt"
import "core:strings"
import parser "mimir:parser"
import core "mimir:core"

// SAF006 — Regex catastrophic backtracking: nested quantifiers
check_regex_catastrophic :: proc(ctx: ^Safety_Context) {
	visitor := core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			ctx := cast(^Safety_Context)raw_ctx
			check_expr_regex(ctx, expr)
		},
		ctx = rawptr(ctx),
	}
	core.walk_all_stmts(&visitor, ctx.module.body)
}

check_expr_regex :: proc(ctx: ^Safety_Context, expr: parser.Expr) {
	if expr == nil { return }
	call, is_call := expr.(^parser.Call_Expr)
	if !is_call { return }

	if !is_regex_call(call) { return }
	if len(call.args) == 0 { return }

	// First arg should be a string literal (the pattern)
	pattern := get_string_literal(call.args[0])
	if len(pattern) == 0 { return }

	if has_catastrophic_backtracking(pattern) {
		append(&ctx.diagnostics, core.Diagnostic{
			severity = .Warning,
			location = core.Location{
				file   = ctx.file_path,
				line   = int(call.loc.line),
				column = int(call.loc.col),
			},
			what = "regex pattern has nested quantifiers that cause catastrophic backtracking",
			why  = "patterns like (a+)+ cause exponential time on non-matching input (ReDoS)",
			fix  = "use atomic groups, possessive quantifiers, or restructure the pattern",
			code = "SAF006",
		})
	}
}

is_regex_call :: proc(call: ^parser.Call_Expr) -> bool {
	// re.compile, re.match, re.search, re.findall, re.sub, re.fullmatch
	attr, is_attr := call.func.(^parser.Attribute_Expr)
	if !is_attr { return false }

	base, is_name := attr.value.(^parser.Name_Expr)
	if !is_name || base.id != "re" { return false }

	RE_FUNCS :: [?]string{"compile", "match", "search", "findall", "sub", "fullmatch", "finditer", "split"}
	for f in RE_FUNCS {
		if attr.attr == f { return true }
	}
	return false
}

get_string_literal :: proc(expr: parser.Expr) -> string {
	if expr == nil { return "" }
	if c, ok := expr.(^parser.Constant_Expr); ok {
		if s, s_ok := c.value.(string); s_ok {
			return s
		}
	}
	return ""
}

// Simplified catastrophic backtracking detector:
// Look for quantified groups containing quantified elements: (x+)+ or (x*)*
has_catastrophic_backtracking :: proc(pattern: string) -> bool {
	depth := 0
	inner_quantified := false
	i := 0

	for i < len(pattern) {
		c := pattern[i]

		// Skip escaped characters
		if c == '\\' {
			i += 2
			continue
		}

		if c == '(' {
			depth += 1
			inner_quantified = false
			i += 1
			// Skip non-capturing group prefix (?:, (?P<, etc.
			if i < len(pattern) && pattern[i] == '?' {
				for i < len(pattern) && pattern[i] != ')' && pattern[i] != ':' && pattern[i] != '<' {
					i += 1
				}
				if i < len(pattern) && (pattern[i] == ':' || pattern[i] == '<') {
					i += 1
				}
			}
			continue
		}

		if c == ')' {
			if depth > 0 {
				was_inner := inner_quantified
				depth -= 1
				inner_quantified = false
				i += 1

				// Check if closing paren is followed by a quantifier
				if was_inner && i < len(pattern) {
					q := pattern[i]
					if q == '+' || q == '*' {
						return true
					}
					if q == '{' {
						return true
					}
				}
				continue
			}
		}

		// Check for quantifiers inside groups
		if depth > 0 && (c == '+' || c == '*') {
			inner_quantified = true
		}
		if depth > 0 && c == '{' {
			inner_quantified = true
		}

		i += 1
	}

	return false
}

// ==================== Logging Rules ====================

// SAF007 — Sensitive data in log calls
check_sensitive_log_data :: proc(ctx: ^Safety_Context) {
	walk_stmts_log_shared(ctx, true)
}

// SAF008 — Expensive log formatting
check_expensive_log_format :: proc(ctx: ^Safety_Context) {
	walk_stmts_log_shared(ctx, false)
}

Log_Walk_Context :: struct {
	safety_ctx:     ^Safety_Context,
	sensitive_mode: bool,
}

walk_stmts_log_shared :: proc(ctx: ^Safety_Context, sensitive_mode: bool) {
	lwc := Log_Walk_Context{safety_ctx = ctx, sensitive_mode = sensitive_mode}
	visitor := core.AST_Visitor{
		visit_stmt = proc(stmt: parser.Stmt, raw_ctx: rawptr) {
			lwc := cast(^Log_Walk_Context)raw_ctx
			#partial switch s in stmt {
			case ^parser.Expr_Stmt:
				check_log_call(lwc.safety_ctx, s.value, lwc.sensitive_mode)
			}
		},
		ctx = rawptr(&lwc),
	}
	core.walk_all_stmts(&visitor, ctx.module.body)
}

check_log_call :: proc(ctx: ^Safety_Context, expr: parser.Expr, sensitive_mode: bool) {
	if expr == nil { return }
	call, is_call := expr.(^parser.Call_Expr)
	if !is_call { return }

	level := get_log_level(call)
	if level == "" { return }

	if sensitive_mode {
		// SAF007: check for sensitive variable names in arguments
		for arg in call.args {
			names := collect_fstring_names(arg, ctx.allocator)
			for name in names {
				if is_sensitive_name(name) {
					append(&ctx.diagnostics, core.Diagnostic{
						severity = .Warning,
						location = core.Location{
							file   = ctx.file_path,
							line   = int(call.loc.line),
							column = int(call.loc.col),
						},
						what = fmt.tprintf("sensitive variable '%s' logged at %s level", name, level),
						why  = "logging sensitive data (passwords, tokens, keys) may expose credentials",
						fix  = "redact or mask sensitive values before logging",
						code = "SAF007",
					})
				}
			}
		}
	} else {
		// SAF008: check for expensive formatting in debug/info
		if level != "debug" && level != "info" { return }

		if len(call.args) == 0 { return }
		arg := call.args[0]

		// f-string with function calls inside
		if fstr, is_fstr := arg.(^parser.Joined_Str); is_fstr {
			for v in fstr.values {
				if fv, is_fv := v.(^parser.Formatted_Value); is_fv {
					if _, is_inner_call := fv.value.(^parser.Call_Expr); is_inner_call {
						append(&ctx.diagnostics, core.Diagnostic{
							severity = .Warning,
							location = core.Location{
								file   = ctx.file_path,
								line   = int(call.loc.line),
								column = int(call.loc.col),
							},
							what = fmt.tprintf("expensive formatting in %s() call", level),
							why  = "f-string expressions evaluate even when log level is disabled",
							fix  = fmt.tprintf("use logger.isEnabledFor() guard or %%s lazy formatting"),
							code = "SAF008",
						})
						return
					}
				}
			}
		}
	}
}

get_log_level :: proc(call: ^parser.Call_Expr) -> string {
	attr, is_attr := call.func.(^parser.Attribute_Expr)
	if !is_attr { return "" }

	LOG_LEVELS :: [?]string{"debug", "info", "warning", "error", "critical"}
	for lvl in LOG_LEVELS {
		if attr.attr == lvl { return lvl }
	}
	return ""
}

collect_fstring_names :: proc(expr: parser.Expr, allocator := context.allocator) -> []string {
	if expr == nil { return nil }
	result := make([dynamic]string, 0, 4, allocator)

	if fstr, is_fstr := expr.(^parser.Joined_Str); is_fstr {
		for v in fstr.values {
			if fv, is_fv := v.(^parser.Formatted_Value); is_fv {
				if name, is_name := fv.value.(^parser.Name_Expr); is_name {
					append(&result, name.id)
				}
			}
		}
	}

	return result[:]
}

SENSITIVE_PATTERNS :: [?]string{
	"password", "passwd", "secret", "token", "api_key", "apikey",
	"private_key", "credit_card", "card_number", "ssn", "auth_token",
	"access_token", "refresh_token",
}

is_sensitive_name :: proc(name: string) -> bool {
	lower := strings.to_lower(name, context.temp_allocator)
	for pattern in SENSITIVE_PATTERNS {
		if strings.contains(lower, pattern) { return true }
	}
	return false
}

// ==================== SAF011: Mutable Class Variable ====================
// Class-level mutable assignments (list, dict, set) are shared across all instances.

check_mutable_class_var :: proc(ctx: ^Safety_Context) {
	visitor := core.AST_Visitor{
		visit_stmt = proc(stmt: parser.Stmt, raw_ctx: rawptr) {
			sctx := cast(^Safety_Context)raw_ctx
			#partial switch s in stmt {
			case ^parser.Class_Def:
				for body_stmt in s.body {
					#partial switch bs in body_stmt {
					case ^parser.Assign:
						if len(bs.targets) == 1 {
							if name, ok := bs.targets[0].(^parser.Name_Expr); ok {
								if _is_mutable_value(bs.value) {
									append(&sctx.diagnostics, core.Diagnostic{
										severity = .Warning,
										location = core.Location{
											file   = sctx.file_path,
											line   = int(bs.loc.line),
											column = int(bs.loc.col),
										},
										what = fmt.tprintf("mutable class variable '%s' is shared across all instances", name.id),
										why  = "list, dict, and set class variables are shared — mutations in one instance affect all others",
										fix  = fmt.tprintf("initialize in __init__: self.%s = %s", name.id, _mutable_type_hint(bs.value)),
										code = "SAF011",
									})
								}
							}
						}
					}
				}
			}
		},
		ctx = rawptr(ctx),
	}
	core.walk_all_stmts(&visitor, ctx.module.body)
}

_is_mutable_value :: proc(expr: parser.Expr) -> bool {
	if expr == nil { return false }
	#partial switch _ in expr {
	case ^parser.List_Expr: return true
	case ^parser.Dict_Expr: return true
	case ^parser.Set_Expr:  return true
	}
	if call, ok := expr.(^parser.Call_Expr); ok {
		if name, nok := call.func.(^parser.Name_Expr); nok {
			return name.id == "list" || name.id == "dict" || name.id == "set"
		}
	}
	return false
}

_mutable_type_hint :: proc(expr: parser.Expr) -> string {
	if expr == nil { return "[]" }
	#partial switch _ in expr {
	case ^parser.List_Expr: return "[]"
	case ^parser.Dict_Expr: return "{}"
	case ^parser.Set_Expr:  return "set()"
	}
	return "[]"
}

// ==================== SAF012: open() Without Context Manager ====================
// open() at module level or in function body without 'with' statement.

check_open_without_with :: proc(ctx: ^Safety_Context) {
	// Scan function bodies for open() calls not inside with blocks
	for stmt in ctx.module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			_check_open_in_body(s.body, ctx, false)
		case ^parser.Async_Func_Def:
			_check_open_in_body(s.body, ctx, false)
		// Module level open() is already caught by SAF003 (import side effect)
		}
	}
}

_check_open_in_body :: proc(stmts: []parser.Stmt, ctx: ^Safety_Context, in_with: bool) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Assign:
			if !in_with && s.value != nil && _is_open_call(s.value) {
				append(&ctx.diagnostics, core.Diagnostic{
					severity = .Warning,
					location = core.Location{
						file   = ctx.file_path,
						line   = int(s.loc.line),
						column = int(s.loc.col),
					},
					what = "open() without context manager",
					why  = "file handles opened without 'with' may not be closed on exceptions, causing resource leaks",
					fix  = "use 'with open(...) as f:' to ensure the file is closed",
					code = "SAF012",
				})
			}
		case ^parser.With_Stmt:
			_check_open_in_body(s.body, ctx, true)
		case ^parser.Async_With:
			_check_open_in_body(s.body, ctx, true)
		case ^parser.If_Stmt:
			_check_open_in_body(s.body, ctx, in_with)
			_check_open_in_body(s.orelse, ctx, in_with)
		case ^parser.For_Stmt:
			_check_open_in_body(s.body, ctx, in_with)
		case ^parser.While_Stmt:
			_check_open_in_body(s.body, ctx, in_with)
		case ^parser.Try_Stmt:
			// open() inside try is tolerated — exception handling serves as cleanup
			_check_open_in_body(s.body, ctx, true)
			for h in s.handlers { _check_open_in_body(h.body, ctx, in_with) }
			_check_open_in_body(s.orelse, ctx, in_with)
			_check_open_in_body(s.finalbody, ctx, in_with)
		}
	}
}

_is_open_call :: proc(expr: parser.Expr) -> bool {
	call, ok := expr.(^parser.Call_Expr)
	if !ok { return false }
	if name, nok := call.func.(^parser.Name_Expr); nok {
		return name.id == "open"
	}
	return false
}
