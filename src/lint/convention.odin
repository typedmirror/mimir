package lint

import "core:fmt"
import "core:strings"
import parser "mimir:parser"
import binder "mimir:binder"
import core "mimir:core"

// C001 — Naming convention

Naming_Context :: struct {
	lint_ctx: ^Lint_Context,
	depth:    int,  // 0 = module level, >0 = inside func/class
}

check_naming_convention :: proc(ctx: ^Lint_Context) {
	nc := Naming_Context{lint_ctx = ctx, depth = 0}
	visitor := core.AST_Visitor{
		visit_stmt = proc(stmt: parser.Stmt, raw_ctx: rawptr) {
			nc := cast(^Naming_Context)raw_ctx
			lint_ctx := nc.lint_ctx
			#partial switch s in stmt {
			case ^parser.Func_Def:
				if !is_dunder(s.name) && !is_snake_case(s.name) {
					append(&lint_ctx.diagnostics, core.Diagnostic{
						severity = .Suggestion,
						location = core.Location{
							file   = lint_ctx.file_path,
							line   = int(s.loc.line),
							column = int(s.loc.col),
						},
						what = fmt.tprintf("function '%s' should use snake_case", s.name),
						why  = "PEP 8 recommends snake_case for function names",
						fix  = "rename to snake_case",
						code = "C001",
					})
				}
				nc.depth += 1
			case ^parser.Async_Func_Def:
				if !is_dunder(s.name) && !is_snake_case(s.name) {
					append(&lint_ctx.diagnostics, core.Diagnostic{
						severity = .Suggestion,
						location = core.Location{
							file   = lint_ctx.file_path,
							line   = int(s.loc.line),
							column = int(s.loc.col),
						},
						what = fmt.tprintf("function '%s' should use snake_case", s.name),
						why  = "PEP 8 recommends snake_case for function names",
						fix  = "rename to snake_case",
						code = "C001",
					})
				}
				nc.depth += 1
			case ^parser.Class_Def:
				if !is_pascal_case(s.name) {
					append(&lint_ctx.diagnostics, core.Diagnostic{
						severity = .Suggestion,
						location = core.Location{
							file   = lint_ctx.file_path,
							line   = int(s.loc.line),
							column = int(s.loc.col),
						},
						what = fmt.tprintf("class '%s' should use PascalCase", s.name),
						why  = "PEP 8 recommends PascalCase (CapWords) for class names",
						fix  = "rename to PascalCase",
						code = "C001",
					})
				}
				nc.depth += 1
			}
		},
		leave_stmt = proc(stmt: parser.Stmt, raw_ctx: rawptr) {
			nc := cast(^Naming_Context)raw_ctx
			#partial switch _ in stmt {
			case ^parser.Func_Def:
				nc.depth -= 1
			case ^parser.Async_Func_Def:
				nc.depth -= 1
			case ^parser.Class_Def:
				nc.depth -= 1
			}
		},
		ctx = rawptr(&nc),
	}
	core.walk_all_stmts(&visitor, ctx.module.body)
}

is_snake_case :: proc(name: string) -> bool {
	if len(name) == 0 { return true }
	// Allow leading underscores
	start := 0
	for start < len(name) && name[start] == '_' { start += 1 }
	if start == len(name) { return true } // all underscores is fine

	for i := start; i < len(name); i += 1 {
		c := name[i]
		if c >= 'a' && c <= 'z' { continue }
		if c >= '0' && c <= '9' { continue }
		if c == '_' { continue }
		return false  // uppercase letter found
	}
	return true
}

is_pascal_case :: proc(name: string) -> bool {
	if len(name) == 0 { return true }
	// First char must be uppercase
	if name[0] < 'A' || name[0] > 'Z' { return false }
	// Allow leading underscore (e.g., _PrivateClass) — but that's not PascalCase
	// Rest can be alphanumeric
	has_lower := false
	for i := 1; i < len(name); i += 1 {
		c := name[i]
		if c >= 'a' && c <= 'z' { has_lower = true; continue }
		if c >= 'A' && c <= 'Z' { continue }
		if c >= '0' && c <= '9' { continue }
		if c == '_' { continue }  // Allow underscores in class names
		return false
	}
	// ALLCAPS (like "ABC") should not pass as PascalCase — require at least one lowercase letter
	if len(name) > 1 {
		return has_lower
	}
	return true
}

is_dunder :: proc(name: string) -> bool {
	return len(name) > 4 && strings.has_prefix(name, "__") && strings.has_suffix(name, "__")
}

// C002 — Star import
check_star_import :: proc(ctx: ^Lint_Context) {
	for &imp in ctx.bind_result.imports {
		if imp.is_star {
			append(&ctx.diagnostics, core.Diagnostic{
				severity = .Warning,
				location = core.Location{
					file   = ctx.file_path,
					line   = int(imp.loc.line),
					column = int(imp.loc.col),
				},
				what = fmt.tprintf("'from %s import *' used", imp.module_name),
				why  = "wildcard imports make it unclear which names are in scope and can cause name collisions",
				fix  = "import specific names instead",
				code = "C002",
			})
		}
	}
}
