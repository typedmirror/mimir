package lint

import "core:fmt"
import "core:strings"
import parser "mimir:parser"
import binder "mimir:binder"
import core "mimir:core"

// L001 — Unused import
check_unused_import :: proc(ctx: ^Lint_Context) {
	br := ctx.bind_result

	// Names imported FROM __future__ (e.g. `from __future__ import annotations`
	// binds the name `annotations`, not `__future__`). These are compiler
	// directives (PEP 236) — they are never "used" in code and must never be
	// flagged as unused.
	future_names := make(map[string]bool, 2, context.temp_allocator)
	for &imp in br.imports {
		if imp.module_name != "__future__" { continue }
		for name in imp.names {
			local := name.alias if len(name.alias) > 0 else name.name
			future_names[local] = true
		}
	}

	// Collect all imported symbols
	for &sym in br.symbols {
		if .Is_Imported not_in sym.flags { continue }

		// Exceptions: __all__, __future__ imports, typing imports
		if sym.name == "__all__" || sym.name == "__future__" { continue }
		if sym.name in future_names { continue }
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
	visitor := core.AST_Visitor{
		visit_stmt = proc(stmt: parser.Stmt, raw_ctx: rawptr) {
			lint_ctx := cast(^Lint_Context)raw_ctx
			#partial switch s in stmt {
			case ^parser.Func_Def:
				check_defaults_mutable(lint_ctx, s.args.defaults)
				check_defaults_mutable(lint_ctx, s.args.kw_defaults)
			case ^parser.Async_Func_Def:
				check_defaults_mutable(lint_ctx, s.args.defaults)
				check_defaults_mutable(lint_ctx, s.args.kw_defaults)
			}
		},
		ctx = rawptr(ctx),
	}
	core.walk_all_stmts(&visitor, ctx.module.body)
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
	visitor := core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			lint_ctx := cast(^Lint_Context)raw_ctx
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
					append(&lint_ctx.diagnostics, core.Diagnostic{
						severity = .Warning,
						location = core.Location{
							file   = lint_ctx.file_path,
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
		},
		ctx = rawptr(ctx),
	}
	core.walk_all_stmts(&visitor, ctx.module.body)
}

// L005 — Bare except
check_bare_except :: proc(ctx: ^Lint_Context) {
	visitor := core.AST_Visitor{
		visit_stmt = proc(stmt: parser.Stmt, raw_ctx: rawptr) {
			lint_ctx := cast(^Lint_Context)raw_ctx
			#partial switch s in stmt {
			case ^parser.Try_Stmt:
				for h in s.handlers {
					if h.type == nil {
						append(&lint_ctx.diagnostics, core.Diagnostic{
							severity = .Warning,
							location = core.Location{
								file   = lint_ctx.file_path,
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
			}
		},
		ctx = rawptr(ctx),
	}
	core.walk_all_stmts(&visitor, ctx.module.body)
}

// L006 — Assert with tuple
check_assert_tuple :: proc(ctx: ^Lint_Context) {
	visitor := core.AST_Visitor{
		visit_stmt = proc(stmt: parser.Stmt, raw_ctx: rawptr) {
			lint_ctx := cast(^Lint_Context)raw_ctx
			#partial switch s in stmt {
			case ^parser.Assert_Stmt:
				if _, ok := s.test.(^parser.Tuple_Expr); ok {
					append(&lint_ctx.diagnostics, core.Diagnostic{
						severity = .Warning,
						location = core.Location{
							file   = lint_ctx.file_path,
							line   = int(s.loc.line),
							column = int(s.loc.col),
						},
						what = "assert called with a tuple",
						why  = "assert(cond, msg) creates a tuple which is always truthy; the assertion never fails",
						fix  = "use 'assert condition, message' without parentheses around both arguments",
						code = "L006",
					})
				}
			}
		},
		ctx = rawptr(ctx),
	}
	core.walk_all_stmts(&visitor, ctx.module.body)
}

// L007 — Comparison to True/False (use truthiness)
check_compare_to_bool :: proc(ctx: ^Lint_Context) {
	visitor := core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			lint_ctx := cast(^Lint_Context)raw_ctx
			cmp, ok := expr.(^parser.Compare_Expr)
			if !ok { return }
			for i in 0..<len(cmp.ops) {
				if cmp.ops[i] != .Eq && cmp.ops[i] != .Not_Eq { continue }
				comp := cmp.comparators[i] if i < len(cmp.comparators) else nil
				if comp == nil { continue }
				if _is_bool_literal(comp) || (i == 0 && _is_bool_literal(cmp.left)) {
					op_str := "==" if cmp.ops[i] == .Eq else "!="
					append(&lint_ctx.diagnostics, core.Diagnostic{
						severity = .Warning,
						location = core.Location{
							file   = lint_ctx.file_path,
							line   = int(cmp.loc.line),
							column = int(cmp.loc.col),
						},
						what = fmt.tprintf("comparison to True/False with '%s'", op_str),
						why  = "use truthiness testing directly instead of comparing to True/False",
						fix  = "use 'if x:' instead of 'if x == True:' (or 'if not x:' for False)",
						code = "L007",
					})
					break
				}
			}
		},
		ctx = rawptr(ctx),
	}
	core.walk_all_stmts(&visitor, ctx.module.body)
}

// L008 — Comparison to None using == instead of is
check_compare_to_none :: proc(ctx: ^Lint_Context) {
	visitor := core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			lint_ctx := cast(^Lint_Context)raw_ctx
			cmp, ok := expr.(^parser.Compare_Expr)
			if !ok { return }
			for i in 0..<len(cmp.ops) {
				if cmp.ops[i] != .Eq && cmp.ops[i] != .Not_Eq { continue }
				comp := cmp.comparators[i] if i < len(cmp.comparators) else nil
				if comp == nil { continue }
				if _is_none_literal(comp) || (i == 0 && _is_none_literal(cmp.left)) {
					op_str := "==" if cmp.ops[i] == .Eq else "!="
					is_str := "is" if cmp.ops[i] == .Eq else "is not"
					append(&lint_ctx.diagnostics, core.Diagnostic{
						severity = .Warning,
						location = core.Location{
							file   = lint_ctx.file_path,
							line   = int(cmp.loc.line),
							column = int(cmp.loc.col),
						},
						what = fmt.tprintf("comparison to None using '%s'", op_str),
						why  = "None is a singleton; use 'is' for identity comparison, not '==' for equality",
						fix  = fmt.tprintf("use '%s None' instead of '%s None'", is_str, op_str),
						code = "L008",
					})
					break
				}
			}
		},
		ctx = rawptr(ctx),
	}
	core.walk_all_stmts(&visitor, ctx.module.body)
}

// L009 — type(x) == Y instead of isinstance(x, Y)
check_type_equality :: proc(ctx: ^Lint_Context) {
	visitor := core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			lint_ctx := cast(^Lint_Context)raw_ctx
			cmp, ok := expr.(^parser.Compare_Expr)
			if !ok { return }
			if len(cmp.ops) != 1 || len(cmp.comparators) != 1 { return }
			if cmp.ops[0] != .Eq && cmp.ops[0] != .Not_Eq && cmp.ops[0] != .Is && cmp.ops[0] != .Is_Not { return }
			if _is_type_call(cmp.left) || _is_type_call(cmp.comparators[0]) {
				append(&lint_ctx.diagnostics, core.Diagnostic{
					severity = .Warning,
					location = core.Location{
						file   = lint_ctx.file_path,
						line   = int(cmp.loc.line),
						column = int(cmp.loc.col),
					},
					what = "comparing type() result directly",
					why  = "type(x) == Y does not account for subclasses; isinstance() is safer",
					fix  = "use isinstance(x, Y) instead of type(x) == Y",
					code = "L009",
				})
			}
		},
		ctx = rawptr(ctx),
	}
	core.walk_all_stmts(&visitor, ctx.module.body)
}

// Helpers
_is_bool_literal :: proc(expr: parser.Expr) -> bool {
	if name, ok := expr.(^parser.Name_Expr); ok {
		return name.id == "True" || name.id == "False"
	}
	if c, ok := expr.(^parser.Constant_Expr); ok {
		_, is_bool := c.value.(bool)
		return is_bool
	}
	return false
}

_is_none_literal :: proc(expr: parser.Expr) -> bool {
	if name, ok := expr.(^parser.Name_Expr); ok {
		return name.id == "None"
	}
	if c, ok := expr.(^parser.Constant_Expr); ok {
		_, is_none := c.value.(parser.Const_None)
		return is_none
	}
	return false
}

_is_type_call :: proc(expr: parser.Expr) -> bool {
	call, ok := expr.(^parser.Call_Expr)
	if !ok { return false }
	name, name_ok := call.func.(^parser.Name_Expr)
	if !name_ok { return false }
	return name.id == "type" && len(call.args) == 1
}

// L010 — `is` comparison with literal (x is 1, x is "hello")
// `is` tests identity, not equality. With literals, it's always wrong.
check_is_with_literal :: proc(ctx: ^Lint_Context) {
	visitor := core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			ctx := cast(^Lint_Context)raw_ctx
			cmp, ok := expr.(^parser.Compare_Expr)
			if !ok { return }
			for op, i in cmp.ops {
				if op != .Is && op != .Is_Not { continue }
				if i >= len(cmp.comparators) { continue }
				comp := cmp.comparators[i]
				if _is_literal_value(comp) {
					op_str := "is" if op == .Is else "is not"
					eq_str := "==" if op == .Is else "!="
					append(&ctx.diagnostics, core.Diagnostic{
						severity = .Warning,
						location = core.Location{
							file   = ctx.file_path,
							line   = int(cmp.loc.line),
							column = int(cmp.loc.col),
						},
						code = "L010",
						what = fmt.tprintf("'%s' used with a literal value", op_str),
						why  = "'is' tests object identity, not equality — with literals, the result is implementation-dependent",
						fix  = fmt.tprintf("use '%s' for value comparison instead of '%s'", eq_str, op_str),
					})
				}
				// Also check left side for first comparison
				if i == 0 && _is_literal_value(cmp.left) {
					op_str := "is" if op == .Is else "is not"
					eq_str := "==" if op == .Is else "!="
					append(&ctx.diagnostics, core.Diagnostic{
						severity = .Warning,
						location = core.Location{
							file   = ctx.file_path,
							line   = int(cmp.loc.line),
							column = int(cmp.loc.col),
						},
						code = "L010",
						what = fmt.tprintf("'%s' used with a literal value", op_str),
						why  = "'is' tests object identity — comparing literals with 'is' is unreliable",
						fix  = fmt.tprintf("use '%s' for value comparison", eq_str),
					})
				}
			}
		},
		ctx = rawptr(ctx),
	}
	core.walk_all_stmts(&visitor, ctx.module.body)
}

_is_literal_value :: proc(expr: parser.Expr) -> bool {
	if expr == nil { return false }
	if c, ok := expr.(^parser.Constant_Expr); ok {
		// None, True, False are fine with `is` — only flag numbers and strings
		_, is_none := c.value.(parser.Const_None)
		if is_none { return false }
		_, is_bool := c.value.(bool)
		if is_bool { return false }
		return true // int, float, string, etc.
	}
	return false
}

// L011 — Shadowing builtin names (list = [1,2,3], dict = {}, type = "foo")
check_builtin_shadow :: proc(ctx: ^Lint_Context) {
	BUILTINS :: [?]string{
		"list", "dict", "set", "tuple", "str", "int", "float", "bool", "bytes",
		"type", "id", "len", "range", "print", "input", "open", "map", "filter",
		"zip", "enumerate", "sorted", "reversed", "sum", "min", "max", "abs",
		"any", "all", "hash", "next", "iter", "super", "object", "property",
		"staticmethod", "classmethod", "isinstance", "issubclass", "hasattr",
		"getattr", "setattr", "delattr", "callable", "repr", "format", "vars",
		"dir", "globals", "locals", "exec", "eval", "compile",
	}

	for stmt in ctx.module.body {
		#partial switch s in stmt {
		case ^parser.Assign:
			for target in s.targets {
				if name, ok := target.(^parser.Name_Expr); ok {
					for b in BUILTINS {
						if name.id == b {
							append(&ctx.diagnostics, core.Diagnostic{
								severity = .Warning,
								location = core.Location{
									file   = ctx.file_path,
									line   = int(s.loc.line),
									column = int(s.loc.col),
								},
								code = "L011",
								what = fmt.tprintf("variable '%s' shadows builtin name", name.id),
								why  = "redefining builtin names prevents using them later in the module",
								fix  = fmt.tprintf("rename the variable (e.g., '%s_value', 'my_%s')", name.id, name.id),
							})
							break
						}
					}
				}
			}
		case ^parser.Func_Def:
			for b in BUILTINS {
				if s.name == b {
					append(&ctx.diagnostics, core.Diagnostic{
						severity = .Warning,
						location = core.Location{
							file   = ctx.file_path,
							line   = int(s.loc.line),
							column = int(s.loc.col),
						},
						code = "L011",
						what = fmt.tprintf("function '%s' shadows builtin name", s.name),
						why  = "redefining builtin names prevents using them later in the module",
						fix  = fmt.tprintf("rename the function"),
					})
					break
				}
			}
		}
	}
}

