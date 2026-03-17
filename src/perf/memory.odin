package perf

import "core:fmt"
import parser "mimir:parser"
import core "mimir:core"

// PERF003 — open().read() reads entire file into memory
check_open_read :: proc(ctx: ^Perf_Context) {
	visitor := core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			ctx := cast(^Perf_Context)raw_ctx
			check_expr_open_read(ctx, expr)
		},
		ctx = rawptr(ctx),
	}
	core.walk_all_stmts(&visitor, ctx.module.body)
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
	visitor := core.AST_Visitor{
		visit_stmt = proc(stmt: parser.Stmt, raw_ctx: rawptr) {
			ctx := cast(^Perf_Context)raw_ctx
			#partial switch s in stmt {
			case ^parser.Func_Def:
				check_func_lru_cache(ctx, s.decorator_list, &s.args, s.loc)
			case ^parser.Async_Func_Def:
				check_func_lru_cache(ctx, s.decorator_list, &s.args, s.loc)
			}
		},
		ctx = rawptr(ctx),
	}
	core.walk_all_stmts(&visitor, ctx.module.body)
}

// PERF005 — N+1 query pattern: query call inside a loop
check_nplus1_query :: proc(ctx: ^Perf_Context) {
	// Walk each function; for each loop body, check for query calls
	for stmt in ctx.module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			check_loops_for_queries(ctx, s.body)
		case ^parser.Async_Func_Def:
			check_loops_for_queries(ctx, s.body)
		}
	}
	check_loops_for_queries(ctx, ctx.module.body)
}

check_loops_for_queries :: proc(ctx: ^Perf_Context, stmts: []parser.Stmt) {
	QUERY_METHODS :: [?]string{"query", "filter", "filter_by", "get", "execute", "fetchall", "fetchone", "all", "first"}

	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.For_Stmt:
			// Scan loop body for query calls
			scan_for_query_calls(ctx, s.body, s.loc)
			check_loops_for_queries(ctx, s.body)
		case ^parser.Async_For:
			scan_for_query_calls(ctx, s.body, s.loc)
			check_loops_for_queries(ctx, s.body)
		case ^parser.While_Stmt:
			scan_for_query_calls(ctx, s.body, s.loc)
			check_loops_for_queries(ctx, s.body)
		case ^parser.If_Stmt:
			check_loops_for_queries(ctx, s.body)
			check_loops_for_queries(ctx, s.orelse)
		case ^parser.Func_Def:
			check_loops_for_queries(ctx, s.body)
		case ^parser.Async_Func_Def:
			check_loops_for_queries(ctx, s.body)
		}
	}
}

scan_for_query_calls :: proc(ctx: ^Perf_Context, stmts: []parser.Stmt, loop_loc: parser.Src_Loc) {
	QUERY_METHODS :: [?]string{"query", "filter", "filter_by", "get", "execute", "fetchall", "fetchone", "all", "first"}

	visitor := core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			ctx := cast(^Perf_Context)raw_ctx
			#partial switch e in expr {
			case ^parser.Call_Expr:
				#partial switch f in e.func {
				case ^parser.Attribute_Expr:
					for m in QUERY_METHODS {
						if f.attr == m {
							append(&ctx.diagnostics, core.Diagnostic{
								severity = .Performance,
								location = core.Location{
									file   = ctx.file_path,
									line   = int(e.loc.line),
									column = int(e.loc.col),
								},
								what = fmt.tprintf("database query '.%s()' inside loop (N+1 pattern)", f.attr),
								why  = "executing a query per iteration causes N+1 database round-trips; scales poorly with data size",
								fix  = "use eager loading, a JOIN query, or batch the IDs and query once outside the loop",
								code = "PERF005",
							})
							return
						}
					}
				}
			}
		},
		ctx = rawptr(ctx),
	}
	core.walk_all_stmts(&visitor, stmts)
}

// PERF006 — Unbounded cache: module-level dict growing in function without eviction
check_unbounded_cache :: proc(ctx: ^Perf_Context) {
	// Phase 1: collect module-level dict variables (name = {} or name = dict())
	module_dicts := make(map[string]bool, 8, ctx.allocator)
	for stmt in ctx.module.body {
		#partial switch s in stmt {
		case ^parser.Assign:
			if len(s.targets) == 1 {
				if name, ok := s.targets[0].(^parser.Name_Expr); ok {
					if is_empty_dict(s.value) {
						module_dicts[name.id] = true
					}
				}
			}
		}
	}
	if len(module_dicts) == 0 { return }

	// Phase 2: check function bodies for subscript assignment to module dicts
	for stmt in ctx.module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			check_dict_growth_in_body(ctx, s.body, module_dicts)
		case ^parser.Async_Func_Def:
			check_dict_growth_in_body(ctx, s.body, module_dicts)
		}
	}
}

is_empty_dict :: proc(expr: parser.Expr) -> bool {
	if d, ok := expr.(^parser.Dict_Expr); ok {
		return len(d.keys) == 0
	}
	if c, ok := expr.(^parser.Call_Expr); ok {
		if n, nok := c.func.(^parser.Name_Expr); nok {
			return n.id == "dict" && len(c.args) == 0
		}
	}
	return false
}

check_dict_growth_in_body :: proc(ctx: ^Perf_Context, stmts: []parser.Stmt, module_dicts: map[string]bool) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Assign:
			if len(s.targets) == 1 {
				if sub, ok := s.targets[0].(^parser.Subscript_Expr); ok {
					if name, nok := sub.value.(^parser.Name_Expr); nok {
						if name.id in module_dicts {
							append(&ctx.diagnostics, core.Diagnostic{
								severity = .Performance,
								location = core.Location{
									file   = ctx.file_path,
									line   = int(s.loc.line),
									column = int(s.loc.col),
								},
								what = fmt.tprintf("unbounded cache: module-level dict '%s' grows without eviction", name.id),
								why  = "adding entries without removal causes unbounded memory growth in long-running processes",
								fix  = "use functools.lru_cache, set a max size, or add an eviction policy",
								code = "PERF006",
							})
						}
					}
				}
			}
		case ^parser.If_Stmt:
			check_dict_growth_in_body(ctx, s.body, module_dicts)
			check_dict_growth_in_body(ctx, s.orelse, module_dicts)
		case ^parser.For_Stmt:
			check_dict_growth_in_body(ctx, s.body, module_dicts)
		}
	}
}

// PERF007 — Heavy import at module level
check_heavy_import :: proc(ctx: ^Perf_Context) {
	HEAVY_IMPORTS :: [?]string{"tensorflow", "torch", "keras", "transformers", "scipy", "cv2"}

	for &imp in ctx.bind_result.imports {
		for h in HEAVY_IMPORTS {
			if imp.module_name == h || (len(imp.module_name) > len(h) && imp.module_name[:len(h)] == h && imp.module_name[len(h)] == '.') {
				// Check this is a top-level import (not inside a function)
				// bind_result.imports are all top-level by default from binder
				append(&ctx.diagnostics, core.Diagnostic{
					severity = .Info,
					location = core.Location{
						file = ctx.file_path,
						line = int(imp.loc.line),
					},
					what = fmt.tprintf("heavy import '%s' at module level", imp.module_name),
					why  = "large packages increase import time and memory; delays startup for CLI tools and serverless functions",
					fix  = "move the import inside the function that uses it (lazy import) if not needed at module level",
					code = "PERF007",
				})
				break
			}
		}
	}
}

UNHASHABLE_TYPES := [?]string{"list", "dict", "set", "bytearray"}

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
