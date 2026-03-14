package lint

import "core:fmt"
import "core:strings"
import parser "mimir:parser"
import binder "mimir:binder"
import core "mimir:core"

// L001 — Unused import
check_unused_import :: proc(ctx: ^Lint_Context) {
	br := ctx.bind_result

	// Collect all imported symbols
	for &sym in br.symbols {
		if .Is_Imported not_in sym.flags { continue }

		// Exceptions: __all__, __future__ imports, typing imports
		if sym.name == "__all__" || sym.name == "__future__" { continue }
		if sym.name in br.typing_names { continue }

		// Check if any Load reference exists for this symbol
		used := false
		for key, ref_id in br.refs {
			if ref_id != sym.id { continue }
			// Check if this ref is a Load context (not the import itself)
			// The ref is a rawptr to a Name_Expr
			name_expr := cast(^parser.Name_Expr)key
			if name_expr != nil && name_expr.ctx == .Load {
				used = true
				break
			}
		}

		if !used {
			append(&ctx.diagnostics, core.Diagnostic{
				severity = .Warning,
				location = core.Location{
					file   = ctx.file_path,
					line   = int(sym.def_loc.line),
					column = int(sym.def_loc.col),
				},
				what = fmt.tprintf("'%s' imported but unused", sym.name),
				why  = "unused imports add unnecessary dependencies and clutter the namespace",
				fix  = fmt.tprintf("remove the unused import '%s'", sym.name),
				code = "L001",
			})
		}
	}
}

// L002 — Unused variable
check_unused_variable :: proc(ctx: ^Lint_Context) {
	br := ctx.bind_result

	for &sym in br.symbols {
		if sym.kind != .Variable { continue }
		if .Is_Imported in sym.flags { continue }
		if .Is_Param in sym.flags { continue }

		// Exception: names starting with _
		if len(sym.name) > 0 && sym.name[0] == '_' { continue }
		// Exception: dunder names
		if len(sym.name) > 4 && strings.has_prefix(sym.name, "__") && strings.has_suffix(sym.name, "__") { continue }

		// Must have a Store but no Load
		has_store := .Is_Assigned in sym.flags
		if !has_store { continue }

		has_load := false
		for key, ref_id in br.refs {
			if ref_id != sym.id { continue }
			name_expr := cast(^parser.Name_Expr)key
			if name_expr != nil && name_expr.ctx == .Load {
				has_load = true
				break
			}
		}

		if !has_load {
			// Check scope — only report module-level and function-level
			scope := binder.result_get_scope(br, sym.scope_id)
			if scope == nil { continue }
			if scope.kind != .Module && scope.kind != .Function { continue }

			append(&ctx.diagnostics, core.Diagnostic{
				severity = .Warning,
				location = core.Location{
					file   = ctx.file_path,
					line   = int(sym.def_loc.line),
					column = int(sym.def_loc.col),
				},
				what = fmt.tprintf("local variable '%s' is assigned but never used", sym.name),
				why  = "unused variables may indicate dead code or a missing reference",
				fix  = fmt.tprintf("remove the variable or prefix with '_' to indicate intentional disuse"),
				code = "L002",
			})
		}
	}
}

// L003 — Mutable default argument
check_mutable_default :: proc(ctx: ^Lint_Context) {
	walk_stmts_for_mutable_default(ctx, ctx.module.body)
}

walk_stmts_for_mutable_default :: proc(ctx: ^Lint_Context, stmts: []parser.Stmt) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			check_defaults_mutable(ctx, s.args.defaults)
			check_defaults_mutable(ctx, s.args.kw_defaults)
			walk_stmts_for_mutable_default(ctx, s.body)
		case ^parser.Async_Func_Def:
			check_defaults_mutable(ctx, s.args.defaults)
			check_defaults_mutable(ctx, s.args.kw_defaults)
			walk_stmts_for_mutable_default(ctx, s.body)
		case ^parser.Class_Def:
			walk_stmts_for_mutable_default(ctx, s.body)
		case ^parser.If_Stmt:
			walk_stmts_for_mutable_default(ctx, s.body)
			walk_stmts_for_mutable_default(ctx, s.orelse)
		case ^parser.For_Stmt:
			walk_stmts_for_mutable_default(ctx, s.body)
			walk_stmts_for_mutable_default(ctx, s.orelse)
		case ^parser.While_Stmt:
			walk_stmts_for_mutable_default(ctx, s.body)
			walk_stmts_for_mutable_default(ctx, s.orelse)
		case ^parser.With_Stmt:
			walk_stmts_for_mutable_default(ctx, s.body)
		case ^parser.Try_Stmt:
			walk_stmts_for_mutable_default(ctx, s.body)
			for h in s.handlers { walk_stmts_for_mutable_default(ctx, h.body) }
			walk_stmts_for_mutable_default(ctx, s.orelse)
			walk_stmts_for_mutable_default(ctx, s.finalbody)
		}
	}
}

check_defaults_mutable :: proc(ctx: ^Lint_Context, defaults: []parser.Expr) {
	for d in defaults {
		if d == nil { continue }
		is_mutable := false
		loc: parser.Src_Loc

		#partial switch e in d {
		case ^parser.List_Expr:
			is_mutable = true
			loc = e.loc
		case ^parser.Dict_Expr:
			is_mutable = true
			loc = e.loc
		case ^parser.Set_Expr:
			is_mutable = true
			loc = e.loc
		}

		if is_mutable {
			append(&ctx.diagnostics, core.Diagnostic{
				severity = .Warning,
				location = core.Location{
					file   = ctx.file_path,
					line   = int(loc.line),
					column = int(loc.col),
				},
				what = "mutable default argument",
				why  = "default mutable arguments are shared between calls, leading to unexpected behavior",
				fix  = "use None as default and create the mutable object inside the function body",
				code = "L003",
			})
		}
	}
}

// L004 — f-string without placeholders
check_fstring_no_placeholders :: proc(ctx: ^Lint_Context) {
	walk_stmts_for_fstring(ctx, ctx.module.body)
}

walk_stmts_for_fstring :: proc(ctx: ^Lint_Context, stmts: []parser.Stmt) {
	for stmt in stmts {
		walk_stmt_exprs(ctx, stmt, check_expr_fstring)
	}
}

check_expr_fstring :: proc(ctx: ^Lint_Context, expr: parser.Expr) {
	if expr == nil { return }
	#partial switch e in expr {
	case ^parser.Joined_Str:
		// f-string: check if any value is a Formatted_Value
		has_placeholder := false
		for v in e.values {
			if _, ok := v.(^parser.Formatted_Value); ok {
				has_placeholder = true
				break
			}
		}
		if !has_placeholder {
			append(&ctx.diagnostics, core.Diagnostic{
				severity = .Warning,
				location = core.Location{
					file   = ctx.file_path,
					line   = int(e.loc.line),
					column = int(e.loc.col),
				},
				what = "f-string without placeholders",
				why  = "this f-string has no interpolated expressions, so the 'f' prefix is unnecessary",
				fix  = "remove the 'f' prefix to use a regular string",
				code = "L004",
			})
		}
	}
}

// L005 — Bare except
check_bare_except :: proc(ctx: ^Lint_Context) {
	walk_stmts_for_bare_except(ctx, ctx.module.body)
}

walk_stmts_for_bare_except :: proc(ctx: ^Lint_Context, stmts: []parser.Stmt) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Try_Stmt:
			for h in s.handlers {
				if h.type == nil {
					append(&ctx.diagnostics, core.Diagnostic{
						severity = .Warning,
						location = core.Location{
							file   = ctx.file_path,
							line   = int(h.loc.line),
							column = int(h.loc.col),
						},
						what = "bare except clause",
						why  = "bare 'except:' catches SystemExit, KeyboardInterrupt, and GeneratorExit",
						fix  = "use 'except Exception:' to avoid catching system-exiting exceptions",
						code = "L005",
					})
				}
			}
			walk_stmts_for_bare_except(ctx, s.body)
			for h in s.handlers { walk_stmts_for_bare_except(ctx, h.body) }
			walk_stmts_for_bare_except(ctx, s.orelse)
			walk_stmts_for_bare_except(ctx, s.finalbody)
		case ^parser.Func_Def:
			walk_stmts_for_bare_except(ctx, s.body)
		case ^parser.Async_Func_Def:
			walk_stmts_for_bare_except(ctx, s.body)
		case ^parser.Class_Def:
			walk_stmts_for_bare_except(ctx, s.body)
		case ^parser.If_Stmt:
			walk_stmts_for_bare_except(ctx, s.body)
			walk_stmts_for_bare_except(ctx, s.orelse)
		case ^parser.For_Stmt:
			walk_stmts_for_bare_except(ctx, s.body)
			walk_stmts_for_bare_except(ctx, s.orelse)
		case ^parser.While_Stmt:
			walk_stmts_for_bare_except(ctx, s.body)
			walk_stmts_for_bare_except(ctx, s.orelse)
		case ^parser.With_Stmt:
			walk_stmts_for_bare_except(ctx, s.body)
		}
	}
}

// L006 — Assert with tuple
check_assert_tuple :: proc(ctx: ^Lint_Context) {
	walk_stmts_for_assert_tuple(ctx, ctx.module.body)
}

walk_stmts_for_assert_tuple :: proc(ctx: ^Lint_Context, stmts: []parser.Stmt) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Assert_Stmt:
			if _, ok := s.test.(^parser.Tuple_Expr); ok {
				append(&ctx.diagnostics, core.Diagnostic{
					severity = .Warning,
					location = core.Location{
						file   = ctx.file_path,
						line   = int(s.loc.line),
						column = int(s.loc.col),
					},
					what = "assert called with a tuple",
					why  = "assert(cond, msg) creates a tuple which is always truthy; the assertion never fails",
					fix  = "use 'assert condition, message' without parentheses around both arguments",
					code = "L006",
				})
			}
		case ^parser.Func_Def:
			walk_stmts_for_assert_tuple(ctx, s.body)
		case ^parser.Async_Func_Def:
			walk_stmts_for_assert_tuple(ctx, s.body)
		case ^parser.Class_Def:
			walk_stmts_for_assert_tuple(ctx, s.body)
		case ^parser.If_Stmt:
			walk_stmts_for_assert_tuple(ctx, s.body)
			walk_stmts_for_assert_tuple(ctx, s.orelse)
		case ^parser.For_Stmt:
			walk_stmts_for_assert_tuple(ctx, s.body)
			walk_stmts_for_assert_tuple(ctx, s.orelse)
		case ^parser.While_Stmt:
			walk_stmts_for_assert_tuple(ctx, s.body)
			walk_stmts_for_assert_tuple(ctx, s.orelse)
		case ^parser.With_Stmt:
			walk_stmts_for_assert_tuple(ctx, s.body)
		case ^parser.Try_Stmt:
			walk_stmts_for_assert_tuple(ctx, s.body)
			for h in s.handlers { walk_stmts_for_assert_tuple(ctx, h.body) }
			walk_stmts_for_assert_tuple(ctx, s.orelse)
			walk_stmts_for_assert_tuple(ctx, s.finalbody)
		}
	}
}

// Generic statement-expression walker used by fstring checker
walk_stmt_exprs :: proc(ctx: ^Lint_Context, stmt: parser.Stmt, visit: proc(ctx: ^Lint_Context, expr: parser.Expr)) {
	#partial switch s in stmt {
	case ^parser.Expr_Stmt:
		walk_expr(ctx, s.value, visit)
	case ^parser.Assign:
		walk_expr(ctx, s.value, visit)
		for t in s.targets { walk_expr(ctx, t, visit) }
	case ^parser.Ann_Assign:
		if s.value != nil { walk_expr(ctx, s.value, visit) }
	case ^parser.Return_Stmt:
		if s.value != nil { walk_expr(ctx, s.value, visit) }
	case ^parser.Func_Def:
		for st in s.body { walk_stmt_exprs(ctx, st, visit) }
	case ^parser.Async_Func_Def:
		for st in s.body { walk_stmt_exprs(ctx, st, visit) }
	case ^parser.Class_Def:
		for st in s.body { walk_stmt_exprs(ctx, st, visit) }
	case ^parser.If_Stmt:
		walk_expr(ctx, s.test, visit)
		for st in s.body { walk_stmt_exprs(ctx, st, visit) }
		for st in s.orelse { walk_stmt_exprs(ctx, st, visit) }
	case ^parser.For_Stmt:
		for st in s.body { walk_stmt_exprs(ctx, st, visit) }
		for st in s.orelse { walk_stmt_exprs(ctx, st, visit) }
	case ^parser.While_Stmt:
		walk_expr(ctx, s.test, visit)
		for st in s.body { walk_stmt_exprs(ctx, st, visit) }
		for st in s.orelse { walk_stmt_exprs(ctx, st, visit) }
	case ^parser.With_Stmt:
		for st in s.body { walk_stmt_exprs(ctx, st, visit) }
	case ^parser.Try_Stmt:
		for st in s.body { walk_stmt_exprs(ctx, st, visit) }
		for h in s.handlers { for st in h.body { walk_stmt_exprs(ctx, st, visit) } }
		for st in s.orelse { walk_stmt_exprs(ctx, st, visit) }
		for st in s.finalbody { walk_stmt_exprs(ctx, st, visit) }
	case ^parser.Assert_Stmt:
		walk_expr(ctx, s.test, visit)
		if s.msg != nil { walk_expr(ctx, s.msg, visit) }
	case ^parser.Raise_Stmt:
		if s.exc != nil { walk_expr(ctx, s.exc, visit) }
	}
}

walk_expr :: proc(ctx: ^Lint_Context, expr: parser.Expr, visit: proc(ctx: ^Lint_Context, expr: parser.Expr)) {
	if expr == nil { return }
	visit(ctx, expr)

	#partial switch e in expr {
	case ^parser.Call_Expr:
		walk_expr(ctx, e.func, visit)
		for a in e.args { walk_expr(ctx, a, visit) }
		for kw in e.keywords { walk_expr(ctx, kw.value, visit) }
	case ^parser.Bin_Op_Expr:
		walk_expr(ctx, e.left, visit)
		walk_expr(ctx, e.right, visit)
	case ^parser.Unary_Op_Expr:
		walk_expr(ctx, e.operand, visit)
	case ^parser.Bool_Op_Expr:
		for v in e.values { walk_expr(ctx, v, visit) }
	case ^parser.Compare_Expr:
		walk_expr(ctx, e.left, visit)
		for c in e.comparators { walk_expr(ctx, c, visit) }
	case ^parser.If_Expr:
		walk_expr(ctx, e.test, visit)
		walk_expr(ctx, e.body, visit)
		walk_expr(ctx, e.orelse, visit)
	case ^parser.Dict_Expr:
		for k in e.keys { walk_expr(ctx, k, visit) }
		for v in e.values { walk_expr(ctx, v, visit) }
	case ^parser.Set_Expr:
		for elt in e.elts { walk_expr(ctx, elt, visit) }
	case ^parser.List_Expr:
		for elt in e.elts { walk_expr(ctx, elt, visit) }
	case ^parser.Tuple_Expr:
		for elt in e.elts { walk_expr(ctx, elt, visit) }
	case ^parser.Joined_Str:
		for v in e.values { walk_expr(ctx, v, visit) }
	case ^parser.Formatted_Value:
		walk_expr(ctx, e.value, visit)
	case ^parser.Attribute_Expr:
		walk_expr(ctx, e.value, visit)
	case ^parser.Subscript_Expr:
		walk_expr(ctx, e.value, visit)
		walk_expr(ctx, e.slice, visit)
	case ^parser.Starred_Expr:
		walk_expr(ctx, e.value, visit)
	case ^parser.Named_Expr:
		walk_expr(ctx, e.value, visit)
	case ^parser.List_Comp:
		walk_expr(ctx, e.elt, visit)
		for gen in e.generators {
			walk_expr(ctx, gen.iter, visit)
			for cond in gen.ifs { walk_expr(ctx, cond, visit) }
		}
	case ^parser.Set_Comp:
		walk_expr(ctx, e.elt, visit)
		for gen in e.generators {
			walk_expr(ctx, gen.iter, visit)
			for cond in gen.ifs { walk_expr(ctx, cond, visit) }
		}
	case ^parser.Dict_Comp:
		walk_expr(ctx, e.key, visit)
		walk_expr(ctx, e.value, visit)
		for gen in e.generators {
			walk_expr(ctx, gen.iter, visit)
			for cond in gen.ifs { walk_expr(ctx, cond, visit) }
		}
	case ^parser.Generator_Expr:
		walk_expr(ctx, e.elt, visit)
		for gen in e.generators {
			walk_expr(ctx, gen.iter, visit)
			for cond in gen.ifs { walk_expr(ctx, cond, visit) }
		}
	}
}
