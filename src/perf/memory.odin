package perf

import "core:fmt"
import parser "mimir:parser"
import core "mimir:core"

// PERF003 — open().read() reads entire file into memory
check_open_read :: proc(ctx: ^Perf_Context) {
	walk_stmts_for_open_read(ctx, ctx.module.body)
}

walk_stmts_for_open_read :: proc(ctx: ^Perf_Context, stmts: []parser.Stmt) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Expr_Stmt:
			check_expr_open_read(ctx, s.value)
		case ^parser.Assign:
			check_expr_open_read(ctx, s.value)
		case ^parser.Ann_Assign:
			if s.value != nil { check_expr_open_read(ctx, s.value) }
		case ^parser.Return_Stmt:
			if s.value != nil { check_expr_open_read(ctx, s.value) }
		case ^parser.Func_Def:
			walk_stmts_for_open_read(ctx, s.body)
		case ^parser.Async_Func_Def:
			walk_stmts_for_open_read(ctx, s.body)
		case ^parser.Class_Def:
			walk_stmts_for_open_read(ctx, s.body)
		case ^parser.If_Stmt:
			walk_stmts_for_open_read(ctx, s.body)
			walk_stmts_for_open_read(ctx, s.orelse)
		case ^parser.For_Stmt:
			walk_stmts_for_open_read(ctx, s.body)
			walk_stmts_for_open_read(ctx, s.orelse)
		case ^parser.While_Stmt:
			walk_stmts_for_open_read(ctx, s.body)
			walk_stmts_for_open_read(ctx, s.orelse)
		case ^parser.With_Stmt:
			walk_stmts_for_open_read(ctx, s.body)
		case ^parser.Try_Stmt:
			walk_stmts_for_open_read(ctx, s.body)
			for h in s.handlers { walk_stmts_for_open_read(ctx, h.body) }
			walk_stmts_for_open_read(ctx, s.orelse)
			walk_stmts_for_open_read(ctx, s.finalbody)
		}
	}
}

check_expr_open_read :: proc(ctx: ^Perf_Context, expr: parser.Expr) {
	if expr == nil { return }
	// Pattern: open(...).read() or open(...).readlines()
	// This is a Call_Expr whose func is Attribute_Expr
	call, ok := expr.(^parser.Call_Expr)
	if !ok { return }

	attr, attr_ok := call.func.(^parser.Attribute_Expr)
	if !attr_ok { return }

	// Check method name is "read" or "readlines"
	if attr.attr != "read" && attr.attr != "readlines" { return }

	// Check the value is a Call_Expr whose callee is open()
	inner_call, inner_ok := attr.value.(^parser.Call_Expr)
	if !inner_ok { return }

	// Check callee is "open"
	if name, name_ok := inner_call.func.(^parser.Name_Expr); name_ok {
		if name.id == "open" {
			append(&ctx.diagnostics, core.Diagnostic{
				severity = .Performance,
				location = core.Location{
					file   = ctx.file_path,
					line   = int(call.loc.line),
					column = int(call.loc.col),
				},
				what = "reading entire file into memory",
				why  = "open().read() loads the full file as a single string; for large files this wastes memory",
				fix  = "iterate line by line with 'for line in open(path):' or use a 'with' block",
				code = "PERF003",
			})
		}
	}
}

// PERF004 — Unhashable @lru_cache parameter
check_unhashable_lru_cache :: proc(ctx: ^Perf_Context) {
	walk_stmts_for_lru_cache(ctx, ctx.module.body)
}

UNHASHABLE_TYPES := [?]string{"list", "dict", "set", "bytearray"}

walk_stmts_for_lru_cache :: proc(ctx: ^Perf_Context, stmts: []parser.Stmt) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			check_func_lru_cache(ctx, s.decorator_list, &s.args, s.loc)
			walk_stmts_for_lru_cache(ctx, s.body)
		case ^parser.Async_Func_Def:
			check_func_lru_cache(ctx, s.decorator_list, &s.args, s.loc)
			walk_stmts_for_lru_cache(ctx, s.body)
		case ^parser.Class_Def:
			walk_stmts_for_lru_cache(ctx, s.body)
		case ^parser.If_Stmt:
			walk_stmts_for_lru_cache(ctx, s.body)
			walk_stmts_for_lru_cache(ctx, s.orelse)
		case ^parser.For_Stmt:
			walk_stmts_for_lru_cache(ctx, s.body)
			walk_stmts_for_lru_cache(ctx, s.orelse)
		case ^parser.While_Stmt:
			walk_stmts_for_lru_cache(ctx, s.body)
			walk_stmts_for_lru_cache(ctx, s.orelse)
		case ^parser.With_Stmt:
			walk_stmts_for_lru_cache(ctx, s.body)
		case ^parser.Try_Stmt:
			walk_stmts_for_lru_cache(ctx, s.body)
			for h in s.handlers { walk_stmts_for_lru_cache(ctx, h.body) }
			walk_stmts_for_lru_cache(ctx, s.orelse)
			walk_stmts_for_lru_cache(ctx, s.finalbody)
		}
	}
}

check_func_lru_cache :: proc(ctx: ^Perf_Context, decorators: []parser.Expr, args: ^parser.Arguments, func_loc: parser.Src_Loc) {
	if !has_cache_decorator(ctx, decorators) { return }

	// Check all parameter annotations
	check_args_hashable(ctx, args.posonlyargs)
	check_args_hashable(ctx, args.args)
	check_args_hashable(ctx, args.kwonlyargs)
	if args.vararg != nil { check_arg_hashable(ctx, args.vararg) }
	if args.kwarg != nil { check_arg_hashable(ctx, args.kwarg) }
}

has_cache_decorator :: proc(ctx: ^Perf_Context, decorators: []parser.Expr) -> bool {
	for dec in decorators {
		// Direct name: @lru_cache, @cache
		if name, ok := dec.(^parser.Name_Expr); ok {
			if is_cache_name(ctx, name.id) { return true }
		}
		// Attribute: @functools.lru_cache, @functools.cache
		if attr, ok := dec.(^parser.Attribute_Expr); ok {
			if val, val_ok := attr.value.(^parser.Name_Expr); val_ok {
				mod, has_mod := ctx.import_map[val.id]
				if has_mod && mod == "functools" {
					if attr.attr == "lru_cache" || attr.attr == "cache" { return true }
				}
				if val.id == "functools" {
					if attr.attr == "lru_cache" || attr.attr == "cache" { return true }
				}
			}
		}
		// Call: @lru_cache(maxsize=128), @functools.lru_cache(maxsize=128)
		if call, ok := dec.(^parser.Call_Expr); ok {
			if name, name_ok := call.func.(^parser.Name_Expr); name_ok {
				if is_cache_name(ctx, name.id) { return true }
			}
			if attr, attr_ok := call.func.(^parser.Attribute_Expr); attr_ok {
				if val, val_ok := attr.value.(^parser.Name_Expr); val_ok {
					mod, has_mod := ctx.import_map[val.id]
					if has_mod && mod == "functools" {
						if attr.attr == "lru_cache" || attr.attr == "cache" { return true }
					}
					if val.id == "functools" {
						if attr.attr == "lru_cache" || attr.attr == "cache" { return true }
					}
				}
			}
		}
	}
	return false
}

is_cache_name :: proc(ctx: ^Perf_Context, name: string) -> bool {
	if name != "lru_cache" && name != "cache" { return false }
	// Check that the name resolves to functools
	mod, ok := ctx.import_map[name]
	return ok && mod == "functools"
}

check_args_hashable :: proc(ctx: ^Perf_Context, args: []parser.Arg) {
	for &a in args {
		check_arg_hashable(ctx, &a)
	}
}

check_arg_hashable :: proc(ctx: ^Perf_Context, arg: ^parser.Arg) {
	if arg.annotation == nil { return }
	name, ok := arg.annotation.(^parser.Name_Expr)
	if !ok { return }

	for t in UNHASHABLE_TYPES {
		if name.id == t {
			append(&ctx.diagnostics, core.Diagnostic{
				severity = .Performance,
				location = core.Location{
					file   = ctx.file_path,
					line   = int(name.loc.line),
					column = int(name.loc.col),
				},
				what = fmt.tprintf("parameter '%s' has unhashable type '%s' for @lru_cache", arg.arg, name.id),
				why  = fmt.tprintf("lru_cache requires all arguments to be hashable; %s is mutable and will raise TypeError at runtime", name.id),
				fix  = "use a tuple instead of list, or frozenset instead of set",
				code = "PERF004",
			})
			break
		}
	}
}
