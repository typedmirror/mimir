package concurrency

import "core:fmt"
import parser "mimir:parser"

// CONC002: Unawaited coroutine
// Fires when an Expr_Stmt contains a Call_Expr whose callee is a known async function.
check_unawaited :: proc(ctx: ^Concurrency_Context, stmt: ^parser.Expr_Stmt, in_async: bool) {
	// Only applies inside async functions (coroutines are only meaningful in async context)
	// But also flag at module level — calling async func without await is always a mistake
	call, ok := stmt.value.(^parser.Call_Expr)
	if !ok { return }

	// Check if the call is wrapped in await — Expr_Stmt(Await_Expr(Call_Expr)) won't reach here
	// because Await_Expr is not Call_Expr. But check nested patterns too.

	// Resolve callee name
	name := ""
	display_name := ""
	#partial switch f in call.func {
	case ^parser.Name_Expr:
		name = f.id
		display_name = f.id
	case ^parser.Attribute_Expr:
		name = f.attr
		if recv, ok := f.value.(^parser.Name_Expr); ok {
			display_name = fmt.tprintf("%s.%s", recv.id, f.attr)
		} else {
			display_name = f.attr
		}
	}

	if len(name) == 0 { return }

	// Check if name is a known async function defined in this module
	if _, is_async := ctx.async_funcs[name]; is_async {
		emit(ctx, "CONC002", call.loc,
			fmt.tprintf("coroutine `%s()` is never awaited", display_name),
			"calling an async function without `await` creates a coroutine object that is immediately discarded",
			fmt.tprintf("use `await %s()` or wrap in `asyncio.create_task(%s())`", display_name, display_name))
	}
}

// CONC003: CPU-bound work in threads
// Fires when threading.Thread(target=func) is detected.
check_thread_target :: proc(ctx: ^Concurrency_Context, expr: parser.Expr) {
	if expr == nil { return }
	call, ok := expr.(^parser.Call_Expr)
	if !ok { return }

	// Check if this is threading.Thread(...)
	if !is_threading_thread(ctx, call) { return }

	// Find the target= keyword argument
	target_name := ""
	for kw in call.keywords {
		if kw.arg == "target" {
			if name, is_name := kw.value.(^parser.Name_Expr); is_name {
				target_name = name.id
			}
			break
		}
	}
	// Also check first positional argument (Thread(group, target))
	// But Thread usually uses keyword. Skip positional for now.

	if len(target_name) == 0 { return }

	// Check if the target function has any known IO/GIL-releasing calls
	// For now, simple heuristic: flag all Thread(target=...) and let user judge
	// Future: analyze the target function body for IO calls
	emit(ctx, "CONC003", call.loc,
		fmt.tprintf("`%s` used as thread target — may be CPU-bound", target_name),
		"CPU-bound work in threads gains no parallelism due to the GIL",
		"if CPU-bound, use `multiprocessing.Pool` or `concurrent.futures.ProcessPoolExecutor`")
}

// Check if a call is threading.Thread(...) or Thread(...)
is_threading_thread :: proc(ctx: ^Concurrency_Context, call: ^parser.Call_Expr) -> bool {
	#partial switch f in call.func {
	case ^parser.Name_Expr:
		// from threading import Thread; Thread(...)
		if f.id == "Thread" {
			if mod, ok := ctx.import_map[f.id]; ok {
				return mod == "threading"
			}
		}
	case ^parser.Attribute_Expr:
		// import threading; threading.Thread(...)
		if f.attr == "Thread" {
			if name, ok := f.value.(^parser.Name_Expr); ok {
				if mod, ok2 := ctx.import_map[name.id]; ok2 {
					return mod == "threading"
				}
			}
		}
	}
	return false
}

// CONC004: Non-atomic compound assignment on global variable
check_nonatomic :: proc(ctx: ^Concurrency_Context, stmt: ^parser.Aug_Assign, globals: []string) {
	// Check if the target is a Name_Expr that matches a global declaration
	name, ok := stmt.target.(^parser.Name_Expr)
	if !ok { return }

	for g in globals {
		if g == name.id {
			emit(ctx, "CONC004", stmt.loc,
				fmt.tprintf("compound assignment `%s` is not atomic", name.id),
				"`+=`, `-=`, etc. expand to load-modify-store (3 bytecodes), creating a race condition with threads",
				"use `threading.Lock` to protect shared state, or use `queue.Queue` for thread-safe communication")
			return
		}
	}
}

// CONC005: Event loop deadlock
// Fires when run_until_complete() or asyncio.run() is called inside async def.
check_expr_deadlock :: proc(ctx: ^Concurrency_Context, expr: parser.Expr) {
	if expr == nil { return }

	#partial switch e in expr {
	case ^parser.Call_Expr:
		if is_loop_blocking(ctx, e) {
			call_name := resolve_call_name(ctx, e)
			emit(ctx, "CONC005", e.loc,
				fmt.tprintf("`%s()` inside async function will deadlock", call_name),
				"the event loop is already running — calling a blocking loop method creates a deadlock",
				"use `await` directly instead of wrapping in `run_until_complete()`")
		}
		for arg in e.args { check_expr_deadlock(ctx, arg) }
		for kw in e.keywords { check_expr_deadlock(ctx, kw.value) }
	case ^parser.Bin_Op_Expr:
		check_expr_deadlock(ctx, e.left)
		check_expr_deadlock(ctx, e.right)
	case ^parser.Await_Expr:
		return  // await contents are fine
	}
}

// Check if a call is loop.run_until_complete(...) or asyncio.run(...)
is_loop_blocking :: proc(ctx: ^Concurrency_Context, call: ^parser.Call_Expr) -> bool {
	#partial switch f in call.func {
	case ^parser.Name_Expr:
		// from asyncio import run; run(...)
		if f.id == "run" {
			if mod, ok := ctx.import_map[f.id]; ok {
				return mod == "asyncio"
			}
		}
	case ^parser.Attribute_Expr:
		// asyncio.run(...)
		if f.attr == "run" {
			if name, ok := f.value.(^parser.Name_Expr); ok {
				if mod, ok2 := ctx.import_map[name.id]; ok2 {
					return mod == "asyncio"
				}
			}
		}
		// loop.run_until_complete(...)
		if f.attr == "run_until_complete" {
			// Only flag if receiver is a known asyncio loop variable or asyncio attr
			if name, ok := f.value.(^parser.Name_Expr); ok {
				if mod, ok2 := ctx.import_map[name.id]; ok2 {
					return mod == "asyncio"
				}
				// Heuristic: variable names like "loop", "event_loop" are likely asyncio loops
				if name.id == "loop" || name.id == "event_loop" {
					return true
				}
			}
		}
	}
	return false
}
