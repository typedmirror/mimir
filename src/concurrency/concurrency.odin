package concurrency

import "core:mem"
import "core:strings"
import "core:fmt"
import parser "mimir:parser"
import binder "mimir:binder"
import core "mimir:core"

Concurrency_Context :: struct {
	module:        ^parser.Module,
	bind_result:   ^binder.Bind_Result,
	source:        string,
	file_path:     string,
	diagnostics:   [dynamic]core.Diagnostic,
	import_map:    map[string]string,           // local_name → module_name
	async_funcs:   map[string]parser.Src_Loc,   // name → definition location
	has_threading: bool,                         // threading or multiprocessing imported
	allocator:     mem.Allocator,
}

analyze_concurrency :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	source: string,
	file_path: string,
	allocator: mem.Allocator,
) -> []core.Diagnostic {
	ctx := Concurrency_Context{
		module      = module,
		bind_result = bind_result,
		source      = source,
		file_path   = file_path,
		diagnostics = make([dynamic]core.Diagnostic, 0, 16, allocator),
		import_map  = make(map[string]string, 16, allocator),
		async_funcs = make(map[string]parser.Src_Loc, 8, allocator),
		allocator   = allocator,
	}

	// Pass 1: build import_map and collect async function definitions
	collect_context(&ctx, module.body)

	// Check if threading/multiprocessing is imported
	for _, mod in ctx.import_map {
		if mod == "threading" || mod == "multiprocessing" {
			ctx.has_threading = true
			break
		}
	}

	// Pass 2: run all concurrency rules
	check_stmts(&ctx, module.body, false)

	return ctx.diagnostics[:]
}

// Pass 1: collect imports and async function names
collect_context :: proc(ctx: ^Concurrency_Context, stmts: []parser.Stmt) {
	visitor := core.AST_Visitor{
		visit_stmt = proc(stmt: parser.Stmt, raw_ctx: rawptr) {
			ctx := cast(^Concurrency_Context)raw_ctx
			#partial switch s in stmt {
			case ^parser.Import_Stmt:
				for alias in s.names {
					local := alias.asname if len(alias.asname) > 0 else alias.name
					if len(alias.asname) == 0 {
						for i := 0; i < len(local); i += 1 {
							if local[i] == '.' {
								local = local[:i]
								break
							}
						}
					}
					ctx.import_map[local] = alias.name
				}
			case ^parser.Import_From:
				if s.level > 0 { return }
				for alias in s.names {
					if alias.name == "*" { continue }
					local := alias.asname if len(alias.asname) > 0 else alias.name
					ctx.import_map[local] = s.module
				}
			case ^parser.Async_Func_Def:
				ctx.async_funcs[s.name] = s.loc
			}
		},
		ctx = rawptr(ctx),
	}
	core.walk_all_stmts(&visitor, stmts)
}

// Collect global declarations at THIS scope level only (no recursion into nested functions)
collect_globals :: proc(stmts: []parser.Stmt, globals: ^[dynamic]string) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Global_Stmt:
			for name in s.names {
				append(globals, name)
			}
		case ^parser.If_Stmt:
			collect_globals(s.body, globals)
			collect_globals(s.orelse, globals)
		case ^parser.For_Stmt:
			collect_globals(s.body, globals)
		case ^parser.While_Stmt:
			collect_globals(s.body, globals)
		// Do NOT recurse into Func_Def/Class_Def — different scope
		}
	}
}

// Pass 2: walk statements applying all rules.
// in_async tracks whether we are inside an async function body.
// func_globals carries the globals collected at function scope to avoid re-collecting per block.
check_stmts :: proc(ctx: ^Concurrency_Context, stmts: []parser.Stmt, in_async: bool, func_globals: []string = nil) {
	// For function-level entries, collect globals once; nested blocks reuse the parent's list.
	globals := func_globals

	// Temporary storage only when we are the function-level caller (func_globals is nil)
	own_globals: [dynamic]string
	defer delete(own_globals)
	if ctx.has_threading && globals == nil {
		collect_globals(stmts, &own_globals)
		globals = own_globals[:]
	}

	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Async_Func_Def:
			// Enter async scope — new function, so pass nil to re-collect
			check_stmts(ctx, s.body, true)
		case ^parser.Func_Def:
			// Enter sync scope — new function, so pass nil to re-collect
			check_stmts(ctx, s.body, false)
		case ^parser.Class_Def:
			check_stmts(ctx, s.body, false)
		case ^parser.If_Stmt:
			check_stmts(ctx, s.body, in_async, globals)
			check_stmts(ctx, s.orelse, in_async, globals)
		case ^parser.For_Stmt:
			check_stmts(ctx, s.body, in_async, globals)
			check_stmts(ctx, s.orelse, in_async, globals)
		case ^parser.Async_For:
			check_stmts(ctx, s.body, in_async, globals)
			check_stmts(ctx, s.orelse, in_async, globals)
		case ^parser.While_Stmt:
			check_stmts(ctx, s.body, in_async, globals)
			check_stmts(ctx, s.orelse, in_async, globals)
		case ^parser.With_Stmt:
			check_stmts(ctx, s.body, in_async, globals)
		case ^parser.Async_With:
			check_stmts(ctx, s.body, in_async, globals)
		case ^parser.Try_Stmt:
			check_stmts(ctx, s.body, in_async, globals)
			for h in s.handlers { check_stmts(ctx, h.body, in_async, globals) }
			check_stmts(ctx, s.orelse, in_async, globals)
			check_stmts(ctx, s.finalbody, in_async, globals)

		case ^parser.Expr_Stmt:
			// CONC002: unawaited coroutine (call to async func without await)
			check_unawaited(ctx, s, in_async)
			// CONC001/CONC005: check calls in expression statements
			if in_async {
				check_expr_blocking(ctx, s.value)
				check_expr_deadlock(ctx, s.value)
			}
			// CONC003: threading.Thread(target=...)
			check_thread_target(ctx, s.value)

		case ^parser.Assign:
			// Check RHS expressions for blocking/deadlock in async
			if in_async {
				check_expr_blocking(ctx, s.value)
				check_expr_deadlock(ctx, s.value)
			}
			// CONC003: t = threading.Thread(target=...)
			check_thread_target(ctx, s.value)
			// CONC006: assignment to global in free-threaded context
			if ctx.has_threading {
				check_nogil_unsafe(ctx, stmt, globals)
			}

		case ^parser.Aug_Assign:
			// CONC004: non-atomic compound assignment on global
			if ctx.has_threading {
				check_nonatomic(ctx, s, globals)
			}
			if in_async {
				check_expr_blocking(ctx, s.value)
			}

		case ^parser.Return_Stmt:
			if in_async && s.value != nil {
				check_expr_blocking(ctx, s.value)
				check_expr_deadlock(ctx, s.value)
			}

		case ^parser.Ann_Assign:
			if in_async && s.value != nil {
				check_expr_blocking(ctx, s.value)
			}
		}
	}
}

// Emit a diagnostic
emit :: proc(ctx: ^Concurrency_Context, code: string, loc: parser.Src_Loc,
             what: string, why: string, fix: string) {
	severity := core.Severity.Error if code == "CONC005" else core.Severity.Warning
	append(&ctx.diagnostics, core.Diagnostic{
		severity = severity,
		location = core.Location{
			file   = ctx.file_path,
			line   = int(loc.line),
			column = int(loc.col),
		},
		what = what,
		why  = why,
		fix  = fix,
		code = code,
	})
}
