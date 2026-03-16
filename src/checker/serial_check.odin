package checker

import "core:fmt"
import "core:mem"
import "core:strings"

import parser "mimir:parser"
import binder "mimir:binder"
import core   "mimir:core"

// ==================== Serialization Safety ====================
//
// Post-inference analysis pass for unsafe serialization patterns.
// Extends SEC007 (pickle/yaml) with taint-aware and shelve checks.
//
// Diagnostics:
//   SER001 — Pickle/marshal with tainted data (request/input source)
//   SER002 — shelve.open (uses pickle internally)
//   SER003 — json.dumps(obj.__dict__) may contain non-serializable types

// Entry point — called from checker.odin after type checking.
analyze_serialization :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	has_pickle := false
	has_shelve := false
	has_marshal := false
	has_json := false

	for &imp in bind_result.imports {
		if imp.module_name == "pickle"  { has_pickle = true }
		if imp.module_name == "shelve"  { has_shelve = true }
		if imp.module_name == "marshal" { has_marshal = true }
		if imp.module_name == "json"    { has_json = true }
	}

	if !has_pickle && !has_shelve && !has_marshal && !has_json { return }

	ctx := Serial_Context{
		file_path   = file_path,
		diagnostics = diagnostics,
		has_pickle  = has_pickle,
		has_shelve  = has_shelve,
		has_marshal = has_marshal,
		has_json    = has_json,
	}

	visitor := core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			ctx := cast(^Serial_Context)raw_ctx
			check_serial_call(ctx, expr)
		},
		ctx = rawptr(&ctx),
	}
	core.walk_all_stmts(&visitor, module.body)
}

Serial_Context :: struct {
	file_path:   string,
	diagnostics: ^[dynamic]core.Diagnostic,
	has_pickle:  bool,
	has_shelve:  bool,
	has_marshal: bool,
	has_json:    bool,
}

check_serial_call :: proc(ctx: ^Serial_Context, expr: parser.Expr) {
	call, is_call := expr.(^parser.Call_Expr)
	if !is_call { return }

	attr, is_attr := call.func.(^parser.Attribute_Expr)
	if !is_attr { return }

	base, is_name := attr.value.(^parser.Name_Expr)
	if !is_name { return }

	// SER001: pickle.loads/marshal.loads with tainted-looking argument
	if (ctx.has_pickle && base.id == "pickle") || (ctx.has_marshal && base.id == "marshal") {
		if attr.attr == "loads" || attr.attr == "load" {
			if len(call.args) >= 1 {
				if is_tainted_source(call.args[0]) {
					append(ctx.diagnostics, core.Diagnostic{
						severity = .Error,
						location = core.Location{
							file   = ctx.file_path,
							line   = int(call.loc.line),
							column = int(call.loc.col),
						},
						what = fmt.tprintf("%s.%s() called with potentially untrusted data", base.id, attr.attr),
						why  = "deserializing untrusted data can execute arbitrary code",
						fix  = "use json.loads() or validate the data source is trusted",
						code = "SER001",
					})
				}
			}
		}
		return
	}

	// SER002: shelve.open — uses pickle internally
	if ctx.has_shelve && base.id == "shelve" && attr.attr == "open" {
		append(ctx.diagnostics, core.Diagnostic{
			severity = .Warning,
			location = core.Location{
				file   = ctx.file_path,
				line   = int(call.loc.line),
				column = int(call.loc.col),
			},
			what = "shelve.open() uses pickle internally for serialization",
			why  = "shelve files can execute arbitrary code when opened if they contain malicious pickle data",
			fix  = "use sqlite3 or json-based storage for untrusted data",
			code = "SER002",
		})
		return
	}

	// SER003: json.dumps(obj.__dict__) — may contain non-serializable types
	if ctx.has_json && base.id == "json" {
		if attr.attr == "dumps" || attr.attr == "dump" {
			if len(call.args) >= 1 {
				if is_dict_attr_access(call.args[0]) {
					append(ctx.diagnostics, core.Diagnostic{
						severity = .Warning,
						location = core.Location{
							file   = ctx.file_path,
							line   = int(call.loc.line),
							column = int(call.loc.col),
						},
						what = fmt.tprintf("json.%s() on __dict__ may contain non-serializable types", attr.attr),
						why  = "__dict__ includes all instance attributes, some of which may not be JSON-serializable (datetime, set, bytes, custom objects)",
						fix  = "use a dataclass with asdict(), or explicitly select serializable fields",
						code = "SER003",
					})
				}
			}
		}
	}
}

// Heuristic: check if an expression looks like it comes from an untrusted source.
// Matches: request.body, request.data, request.content, input(...), sys.stdin.read()
is_tainted_source :: proc(expr: parser.Expr) -> bool {
	// request.body, request.data, request.content, req.body, etc.
	if attr, ok := expr.(^parser.Attribute_Expr); ok {
		if name, n_ok := attr.value.(^parser.Name_Expr); n_ok {
			TAINTED_BASES :: [?]string{"request", "req", "data", "body"}
			for tb in TAINTED_BASES {
				if name.id == tb { return true }
			}
		}
		TAINTED_ATTRS :: [?]string{"body", "data", "content", "read"}
		for ta in TAINTED_ATTRS {
			if attr.attr == ta { return true }
		}
	}

	// input(...)
	if call, ok := expr.(^parser.Call_Expr); ok {
		if name, n_ok := call.func.(^parser.Name_Expr); n_ok {
			if name.id == "input" { return true }
		}
	}

	// Variable named with tainted-sounding names
	if name, ok := expr.(^parser.Name_Expr); ok {
		TAINTED_NAMES :: [?]string{
			"body", "data", "payload", "content", "raw_data",
			"request_data", "user_data", "user_input", "network_data",
		}
		lower := strings.to_lower(name.id, context.temp_allocator)
		for tn in TAINTED_NAMES {
			if lower == tn { return true }
		}
	}

	return false
}

// Check if expression is obj.__dict__
is_dict_attr_access :: proc(expr: parser.Expr) -> bool {
	if attr, ok := expr.(^parser.Attribute_Expr); ok {
		return attr.attr == "__dict__"
	}
	return false
}
