package safety

import "core:fmt"
import parser "mimir:parser"
import core "mimir:core"

// SAF009 — Mutable default argument
check_mutable_default :: proc(ctx: ^Safety_Context) {
	walk_stmts_mutable_default(ctx, ctx.module.body)
}

walk_stmts_mutable_default :: proc(ctx: ^Safety_Context, stmts: []parser.Stmt) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			check_func_defaults(ctx, &s.args)
			walk_stmts_mutable_default(ctx, s.body)
		case ^parser.Async_Func_Def:
			check_func_defaults(ctx, &s.args)
			walk_stmts_mutable_default(ctx, s.body)
		case ^parser.Class_Def:
			walk_stmts_mutable_default(ctx, s.body)
		case ^parser.If_Stmt:
			walk_stmts_mutable_default(ctx, s.body)
			walk_stmts_mutable_default(ctx, s.orelse)
		case ^parser.For_Stmt:
			walk_stmts_mutable_default(ctx, s.body)
			walk_stmts_mutable_default(ctx, s.orelse)
		case ^parser.While_Stmt:
			walk_stmts_mutable_default(ctx, s.body)
			walk_stmts_mutable_default(ctx, s.orelse)
		case ^parser.With_Stmt:
			walk_stmts_mutable_default(ctx, s.body)
		case ^parser.Try_Stmt:
			walk_stmts_mutable_default(ctx, s.body)
			for h in s.handlers { walk_stmts_mutable_default(ctx, h.body) }
			walk_stmts_mutable_default(ctx, s.orelse)
			walk_stmts_mutable_default(ctx, s.finalbody)
		}
	}
}

check_func_defaults :: proc(ctx: ^Safety_Context, args: ^parser.Arguments) {
	// Check regular arg defaults
	for d in args.defaults {
		if d != nil && is_mutable_default(d) {
			emit_mutable_default(ctx, d)
		}
	}
	// Check keyword-only arg defaults
	for d in args.kw_defaults {
		if d != nil && is_mutable_default(d) {
			emit_mutable_default(ctx, d)
		}
	}
}

is_mutable_default :: proc(expr: parser.Expr) -> bool {
	#partial switch e in expr {
	case ^parser.List_Expr:
		return true
	case ^parser.Dict_Expr:
		return true
	case ^parser.Set_Expr:
		return true
	case ^parser.Call_Expr:
		// Check for mutable constructor calls: list(), dict(), set(), bytearray()
		if name, ok := e.func.(^parser.Name_Expr); ok {
			switch name.id {
			case "list", "dict", "set", "bytearray":
				return true
			}
		}
	}
	return false
}

default_expr_loc :: proc(expr: parser.Expr) -> parser.Src_Loc {
	if expr == nil { return {} }
	#partial switch e in expr {
	case ^parser.List_Expr:     return e.loc
	case ^parser.Dict_Expr:     return e.loc
	case ^parser.Set_Expr:      return e.loc
	case ^parser.Call_Expr:     return e.loc
	}
	return {}
}

emit_mutable_default :: proc(ctx: ^Safety_Context, expr: parser.Expr) {
	loc := default_expr_loc(expr)
	append(&ctx.diagnostics, core.Diagnostic{
		severity = .Warning,
		location = core.Location{
			file   = ctx.file_path,
			line   = int(loc.line),
			column = int(loc.col),
		},
		what = "mutable default argument",
		why  = "default mutable objects are shared between calls, causing unexpected state",
		fix  = "use None as default and create inside function body",
		code = "SAF009",
	})
}
