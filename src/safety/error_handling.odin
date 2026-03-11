package safety

import "core:fmt"
import parser "mimir:parser"
import core "mimir:core"

// SAF001 — Exception silently swallowed (except ...: pass)
check_exception_swallowed :: proc(ctx: ^Safety_Context) {
	walk_stmts_exception_swallowed(ctx, ctx.module.body)
}

walk_stmts_exception_swallowed :: proc(ctx: ^Safety_Context, stmts: []parser.Stmt) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Try_Stmt:
			for h in s.handlers {
				if is_handler_swallowed(h) {
					type_name := handler_type_name(h)
					append(&ctx.diagnostics, core.Diagnostic{
						severity = .Warning,
						location = core.Location{
							file   = ctx.file_path,
							line   = int(h.loc.line),
							column = int(h.loc.col),
						},
						what = fmt.tprintf("exception silently swallowed%s", type_name),
						why  = "caught exception is ignored with 'pass', hiding potential errors",
						fix  = "log the error, re-raise, or handle it explicitly",
						code = "SAF001",
					})
				}
			}
			walk_stmts_exception_swallowed(ctx, s.body)
			for h in s.handlers { walk_stmts_exception_swallowed(ctx, h.body) }
			walk_stmts_exception_swallowed(ctx, s.orelse)
			walk_stmts_exception_swallowed(ctx, s.finalbody)
		case ^parser.Func_Def:
			walk_stmts_exception_swallowed(ctx, s.body)
		case ^parser.Async_Func_Def:
			walk_stmts_exception_swallowed(ctx, s.body)
		case ^parser.Class_Def:
			walk_stmts_exception_swallowed(ctx, s.body)
		case ^parser.If_Stmt:
			walk_stmts_exception_swallowed(ctx, s.body)
			walk_stmts_exception_swallowed(ctx, s.orelse)
		case ^parser.For_Stmt:
			walk_stmts_exception_swallowed(ctx, s.body)
			walk_stmts_exception_swallowed(ctx, s.orelse)
		case ^parser.While_Stmt:
			walk_stmts_exception_swallowed(ctx, s.body)
			walk_stmts_exception_swallowed(ctx, s.orelse)
		case ^parser.With_Stmt:
			walk_stmts_exception_swallowed(ctx, s.body)
		}
	}
}

// Handler is swallowed if body is only Pass statements
is_handler_swallowed :: proc(h: parser.Exception_Handler) -> bool {
	if len(h.body) == 0 { return true }
	for stmt in h.body {
		if _, is_pass := stmt.(^parser.Pass_Stmt); !is_pass {
			return false
		}
	}
	return true
}

handler_type_name :: proc(h: parser.Exception_Handler) -> string {
	if h.type == nil { return "" }
	if name, ok := h.type.(^parser.Name_Expr); ok {
		return fmt.tprintf(" (%s)", name.id)
	}
	return ""
}

// SAF002 — Overly broad except (except Exception/BaseException)
check_overly_broad_except :: proc(ctx: ^Safety_Context) {
	walk_stmts_broad_except(ctx, ctx.module.body)
}

walk_stmts_broad_except :: proc(ctx: ^Safety_Context, stmts: []parser.Stmt) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Try_Stmt:
			for h in s.handlers {
				if is_overly_broad(h) {
					type_name := handler_type_name(h)
					append(&ctx.diagnostics, core.Diagnostic{
						severity = .Warning,
						location = core.Location{
							file   = ctx.file_path,
							line   = int(h.loc.line),
							column = int(h.loc.col),
						},
						what = fmt.tprintf("overly broad exception handler%s", type_name),
						why  = "catching Exception or BaseException masks specific errors and makes debugging harder",
						fix  = "catch specific exceptions like ValueError, TypeError, KeyError instead",
						code = "SAF002",
					})
				}
			}
			walk_stmts_broad_except(ctx, s.body)
			for h in s.handlers { walk_stmts_broad_except(ctx, h.body) }
			walk_stmts_broad_except(ctx, s.orelse)
			walk_stmts_broad_except(ctx, s.finalbody)
		case ^parser.Func_Def:
			walk_stmts_broad_except(ctx, s.body)
		case ^parser.Async_Func_Def:
			walk_stmts_broad_except(ctx, s.body)
		case ^parser.Class_Def:
			walk_stmts_broad_except(ctx, s.body)
		case ^parser.If_Stmt:
			walk_stmts_broad_except(ctx, s.body)
			walk_stmts_broad_except(ctx, s.orelse)
		case ^parser.For_Stmt:
			walk_stmts_broad_except(ctx, s.body)
			walk_stmts_broad_except(ctx, s.orelse)
		case ^parser.While_Stmt:
			walk_stmts_broad_except(ctx, s.body)
			walk_stmts_broad_except(ctx, s.orelse)
		case ^parser.With_Stmt:
			walk_stmts_broad_except(ctx, s.body)
		}
	}
}

is_overly_broad :: proc(h: parser.Exception_Handler) -> bool {
	if h.type == nil { return false } // bare except is L005
	if name, ok := h.type.(^parser.Name_Expr); ok {
		return name.id == "Exception" || name.id == "BaseException"
	}
	return false
}
