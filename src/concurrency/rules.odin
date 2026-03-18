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

// §6.2: GIL-releasing function database.
// Functions that release the GIL during execution (IO, sleep, network, subprocess).
// Thread targets calling these are IO-bound and correctly use threads.
GIL_RELEASING_MODULES :: [?]string{
	"time",         // time.sleep releases GIL
	"socket",       // all socket ops
	"requests",     // HTTP client
	"urllib",       // HTTP client
	"http",         // HTTP server/client
	"subprocess",   // process management
	"sqlite3",      // database
	"psycopg2",     // PostgreSQL
	"mysql",        // MySQL
	"pymongo",      // MongoDB
	"redis",        // Redis
	"smtplib",      // email
	"ftplib",       // FTP
	"ssl",          // TLS
	"select",       // I/O multiplexing
	"selectors",    // I/O multiplexing
}

GIL_RELEASING_FUNCS :: [?]string{
	"sleep",        // time.sleep
	"open",         // file I/O
	"read",         // file I/O
	"write",        // file I/O
	"recv",         // socket
	"send",         // socket
	"connect",      // socket/db
	"accept",       // socket
	"listen",       // socket
	"get",          // requests.get
	"post",         // requests.post
	"urlopen",      // urllib
	"input",        // stdin blocks
}

// CONC003: CPU-bound work in threads
// Fires when threading.Thread(target=func) is detected AND the target
// function body has no GIL-releasing calls (§6.2).
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

	if len(target_name) == 0 { return }

	// Find the target function's body and check for GIL-releasing calls
	target_body := find_func_body(ctx.module.body, target_name)
	if target_body != nil && has_gil_releasing_call(target_body, ctx) {
		// IO-bound — threads are the correct choice, no warning
		return
	}

	emit(ctx, "CONC003", call.loc,
		fmt.tprintf("`%s` used as thread target — appears CPU-bound", target_name),
		"CPU-bound work in threads gains no parallelism due to the GIL",
		"if CPU-bound, use `multiprocessing.Pool` or `concurrent.futures.ProcessPoolExecutor`")
}

// Find a function's body statements by name in the module
find_func_body :: proc(stmts: []parser.Stmt, name: string) -> []parser.Stmt {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			if s.name == name { return s.body }
		case ^parser.Async_Func_Def:
			if s.name == name { return s.body }
		case ^parser.Class_Def:
			if result := find_func_body(s.body, name); result != nil { return result }
		case ^parser.If_Stmt:
			if result := find_func_body(s.body, name); result != nil { return result }
			if result := find_func_body(s.orelse, name); result != nil { return result }
		}
	}
	return nil
}

// Check if a function body contains any GIL-releasing calls
has_gil_releasing_call :: proc(stmts: []parser.Stmt, ctx: ^Concurrency_Context) -> bool {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Expr_Stmt:
			if _is_gil_releasing_expr(s.value, ctx) { return true }
		case ^parser.Assign:
			if _is_gil_releasing_expr(s.value, ctx) { return true }
		case ^parser.Return_Stmt:
			if s.value != nil && _is_gil_releasing_expr(s.value, ctx) { return true }
		case ^parser.If_Stmt:
			if has_gil_releasing_call(s.body, ctx) { return true }
			if has_gil_releasing_call(s.orelse, ctx) { return true }
		case ^parser.For_Stmt:
			if has_gil_releasing_call(s.body, ctx) { return true }
		case ^parser.While_Stmt:
			if has_gil_releasing_call(s.body, ctx) { return true }
		case ^parser.With_Stmt:
			if has_gil_releasing_call(s.body, ctx) { return true }
		case ^parser.Try_Stmt:
			if has_gil_releasing_call(s.body, ctx) { return true }
			for h in s.handlers { if has_gil_releasing_call(h.body, ctx) { return true } }
		}
	}
	return false
}

// Check if an expression is a call to a known GIL-releasing function
_is_gil_releasing_expr :: proc(expr: parser.Expr, ctx: ^Concurrency_Context) -> bool {
	if expr == nil { return false }
	#partial switch e in expr {
	case ^parser.Call_Expr:
		// Check direct name calls: sleep(), open(), read()
		if name, ok := e.func.(^parser.Name_Expr); ok {
			for f in GIL_RELEASING_FUNCS {
				if name.id == f { return true }
			}
			// Check if name maps to a GIL-releasing module via import_map
			if mod, has := ctx.import_map[name.id]; has {
				for m in GIL_RELEASING_MODULES {
					if mod == m { return true }
				}
			}
		}
		// Check attribute calls: time.sleep(), requests.get(), conn.read()
		if attr, ok := e.func.(^parser.Attribute_Expr); ok {
			// Check method name against GIL-releasing funcs
			for f in GIL_RELEASING_FUNCS {
				if attr.attr == f { return true }
			}
			// Check if receiver is a GIL-releasing module
			if recv_name, ok2 := attr.value.(^parser.Name_Expr); ok2 {
				if mod, has := ctx.import_map[recv_name.id]; has {
					for m in GIL_RELEASING_MODULES {
						if mod == m { return true }
					}
				}
			}
		}
		// Recurse into args
		for arg in e.args {
			if _is_gil_releasing_expr(arg, ctx) { return true }
		}
	case ^parser.Await_Expr:
		return true // await always releases GIL
	}
	return false
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

// CONC006: Free-threaded unsafe — global mutable state without locks
// Fires on any assignment to a global variable inside a function (not just compound).
// Distinct from CONC004 which only catches augmented assignment.
check_nogil_unsafe :: proc(ctx: ^Concurrency_Context, stmt: parser.Stmt, globals: []string) {
	#partial switch s in stmt {
	case ^parser.Assign:
		if len(s.targets) >= 1 {
			if name, ok := s.targets[0].(^parser.Name_Expr); ok {
				for g in globals {
					if g == name.id {
						emit(ctx, "CONC006", s.loc,
							fmt.tprintf("assignment to global '%s' is not thread-safe without GIL", name.id),
							"in free-threaded Python (PEP 703), concurrent writes to shared state cause data races",
							"protect with threading.Lock, use queue.Queue, or make the variable thread-local")
						return
					}
				}
			}
		}
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
