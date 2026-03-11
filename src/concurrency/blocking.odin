package concurrency

import "core:fmt"
import parser "mimir:parser"

// Database of known blocking functions and their async alternatives.

Blocking_Entry :: struct {
	module:      string,   // "" = builtin
	func_name:   string,
	alternative: string,
}

BLOCKING_CALLS := [?]Blocking_Entry{
	// time
	{ "time",            "sleep",        "asyncio.sleep()" },
	// socket
	{ "socket",          "connect",      "asyncio streams or loop.create_connection()" },
	{ "socket",          "recv",         "asyncio streams or loop.sock_recv()" },
	{ "socket",          "send",         "asyncio streams or loop.sock_sendall()" },
	{ "socket",          "accept",       "loop.sock_accept()" },
	// requests
	{ "requests",        "get",          "aiohttp or httpx.AsyncClient" },
	{ "requests",        "post",         "aiohttp or httpx.AsyncClient" },
	{ "requests",        "put",          "aiohttp or httpx.AsyncClient" },
	{ "requests",        "delete",       "aiohttp or httpx.AsyncClient" },
	{ "requests",        "patch",        "aiohttp or httpx.AsyncClient" },
	{ "requests",        "head",         "aiohttp or httpx.AsyncClient" },
	{ "requests",        "request",      "aiohttp or httpx.AsyncClient" },
	// urllib
	{ "urllib.request",  "urlopen",      "aiohttp or httpx.AsyncClient" },
	// subprocess
	{ "subprocess",      "run",          "asyncio.create_subprocess_exec()" },
	{ "subprocess",      "call",         "asyncio.create_subprocess_exec()" },
	{ "subprocess",      "check_output", "asyncio.create_subprocess_exec()" },
	{ "subprocess",      "check_call",   "asyncio.create_subprocess_exec()" },
	// builtin open
	{ "",                "open",         "aiofiles.open()" },
}

// Check if a Call_Expr is a known blocking call.
// Returns (is_blocking, entry) where entry has the alternative suggestion.
is_blocking_call :: proc(ctx: ^Concurrency_Context, call: ^parser.Call_Expr) -> (bool, Blocking_Entry) {
	#partial switch f in call.func {
	case ^parser.Name_Expr:
		// Direct call: open(), sleep() (if imported)
		// Check builtin open
		if f.id == "open" {
			// Only flag if it's the builtin (not imported from somewhere else)
			if _, ok := ctx.import_map[f.id]; !ok {
				return true, Blocking_Entry{ "", "open", "aiofiles.open()" }
			}
		}
		// Check if it's an imported function: from time import sleep
		if mod, ok := ctx.import_map[f.id]; ok {
			for entry in BLOCKING_CALLS {
				if entry.module == mod && entry.func_name == f.id {
					return true, entry
				}
			}
		}
	case ^parser.Attribute_Expr:
		// Attribute call: time.sleep(), requests.get()
		if name, ok := f.value.(^parser.Name_Expr); ok {
			if mod, ok2 := ctx.import_map[name.id]; ok2 {
				for entry in BLOCKING_CALLS {
					if entry.module == mod && entry.func_name == f.attr {
						return true, entry
					}
				}
			}
		}
	}
	return false, {}
}

// Recursively check an expression for blocking calls (CONC001).
// Only called when in_async is true.
check_expr_blocking :: proc(ctx: ^Concurrency_Context, expr: parser.Expr) {
	if expr == nil { return }

	#partial switch e in expr {
	case ^parser.Call_Expr:
		if is_blocking, entry := is_blocking_call(ctx, e); is_blocking {
			call_name := resolve_call_name(ctx, e)
			emit(ctx, "CONC001", e.loc,
				fmt.tprintf("blocking call `%s()` in async function", call_name),
				fmt.tprintf("`%s()` blocks the event loop, preventing other coroutines from running", call_name),
				fmt.tprintf("use `%s` instead", entry.alternative))
		}
		// Also check arguments for nested calls
		for arg in e.args { check_expr_blocking(ctx, arg) }
		for kw in e.keywords { check_expr_blocking(ctx, kw.value) }
	case ^parser.Bin_Op_Expr:
		check_expr_blocking(ctx, e.left)
		check_expr_blocking(ctx, e.right)
	case ^parser.If_Expr:
		check_expr_blocking(ctx, e.body)
		check_expr_blocking(ctx, e.orelse)
	case ^parser.Await_Expr:
		// Don't recurse into await — the awaited call is fine
		return
	}
}

// Resolve a call to a human-readable name like "time.sleep" or "open"
resolve_call_name :: proc(ctx: ^Concurrency_Context, call: ^parser.Call_Expr) -> string {
	#partial switch f in call.func {
	case ^parser.Name_Expr:
		return f.id
	case ^parser.Attribute_Expr:
		if name, ok := f.value.(^parser.Name_Expr); ok {
			return fmt.tprintf("%s.%s", name.id, f.attr)
		}
		return f.attr
	}
	return "<unknown>"
}
