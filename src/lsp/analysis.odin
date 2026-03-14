package lsp

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

import parser     "mimir:parser"
import binder     "mimir:binder"
import flow       "mimir:flow"
import checker    "mimir:checker"
import core       "mimir:core"
import lint       "mimir:lint"
import security   "mimir:security"
import concurrency "mimir:concurrency"
import perf       "mimir:perf"
import safety     "mimir:safety"

// ==================== Analysis Results ====================

Analysis_Result :: struct {
	module:       ^parser.Module,
	bind_result:  binder.Bind_Result,
	flow_result:  flow.Flow_Result,
	check_result: checker.Check_Result,
	all_diags:    [dynamic]core.Diagnostic,
	ok:           bool,
}

// ==================== Pipeline Runner ====================

analyze_document :: proc(
	server: ^Server,
	uri: string,
	content: string,
) -> Analysis_Result {
	result: Analysis_Result

	// Write content to temp file with PID-unique name
	temp_path := fmt.tprintf("/tmp/mimir_lsp_%d.py", os.get_pid())
	write_err := os.write_entire_file(temp_path, transmute([]u8)content)
	if write_err != nil {
		return result
	}

	// 1. Parse
	module, parse_err := parser.bridge_parse(server.bridge, temp_path, server.allocator)
	if parse_err != nil {
		// Create a diagnostic for the parse error
		result.all_diags = make([dynamic]core.Diagnostic, 0, 1, server.allocator)
		#partial switch e in parse_err {
		case parser.Syntax_Error:
			append(&result.all_diags, core.Diagnostic{
				severity = .Error,
				location = core.Location{
					file   = uri,
					line   = e.line,
					column = e.col,
				},
				what = e.msg,
				code = "E000",
			})
		case parser.Bridge_Error:
			append(&result.all_diags, core.Diagnostic{
				severity = .Error,
				location = core.Location{file = uri, line = 1, column = 0},
				what = e.msg,
				code = "E000",
			})
		}
		return result
	}

	result.module = module
	result.ok = true

	// 2. Bind
	result.bind_result = binder.bind(module, temp_path, server.allocator)

	// 3. Flow analyze
	result.flow_result = flow.analyze(module, &result.bind_result, temp_path, server.allocator)

	// 4. Type check
	result.check_result = checker.check(module, &result.bind_result, &result.flow_result, temp_path, server.allocator)

	// 5. Lint
	lint_config := lint.default_config()
	lint_diags := lint.lint_file(module, &result.bind_result, content, temp_path, &lint_config, server.allocator)

	// 6. Security scan
	sec_config := security.default_config()
	sec_diags := security.scan_file(module, &result.bind_result, content, temp_path, &sec_config, server.allocator, &result.flow_result)

	// 7. Concurrency check
	conc_diags := concurrency.analyze_concurrency(module, &result.bind_result, content, temp_path, server.allocator)

	// 8. Performance check
	perf_config := perf.default_config()
	perf_diags := perf.analyze_performance(module, &result.bind_result, content, temp_path, &perf_config, server.allocator)

	// 9. Safety check
	safety_config := safety.default_config()
	safety_diags := safety.analyze_safety(module, &result.bind_result, temp_path, &safety_config, server.allocator)

	// Collect all diagnostics
	total := len(result.bind_result.diagnostics) +
	         len(result.flow_result.diagnostics) +
	         len(result.check_result.diagnostics) +
	         len(lint_diags) + len(sec_diags) + len(conc_diags) + len(perf_diags) + len(safety_diags)

	result.all_diags = make([dynamic]core.Diagnostic, 0, total, server.allocator)

	for d in result.bind_result.diagnostics {
		append(&result.all_diags, d)
	}
	for d in result.flow_result.diagnostics {
		append(&result.all_diags, d)
	}
	for d in result.check_result.diagnostics {
		append(&result.all_diags, d)
	}
	for d in lint_diags {
		append(&result.all_diags, d)
	}
	for d in sec_diags {
		append(&result.all_diags, d)
	}
	for d in conc_diags {
		append(&result.all_diags, d)
	}
	for d in perf_diags {
		append(&result.all_diags, d)
	}
	for d in safety_diags {
		append(&result.all_diags, d)
	}

	return result
}

// ==================== Diagnostic Conversion ====================

convert_severity :: proc(sev: core.Severity) -> int {
	switch sev {
	case .Error:       return 1
	case .Warning:     return 2
	case .Security:    return 1
	case .Performance: return 3
	case .Suggestion:  return 4
	case .Info:        return 3
	}
	return 1
}

diagnostics_to_json :: proc(diags: []core.Diagnostic, uri: string, allocator: mem.Allocator) -> string {
	buf := make([dynamic]u8, 0, len(diags) * 256, allocator)

	// Build JSON array
	append(&buf, '[')
	for d, i in diags {
		if i > 0 { append(&buf, ',') }

		// Convert 1-indexed line to 0-indexed LSP line
		line := d.location.line - 1
		if line < 0 { line = 0 }
		col := d.location.column

		// Build message: what + why + fix
		msg := build_message(d, allocator)
		escaped_msg := json_escape(msg, allocator)
		escaped_code := json_escape(d.code, allocator)

		entry := fmt.aprintf(
			"{{\"range\":{{\"start\":{{\"line\":%d,\"character\":%d}},\"end\":{{\"line\":%d,\"character\":%d}}}},\"severity\":%d,\"code\":\"%s\",\"source\":\"mimir\",\"message\":\"%s\"}}",
			line, col, line, col + 1,
			convert_severity(d.severity),
			escaped_code,
			escaped_msg,
			allocator = allocator,
		)
		for c in entry { append(&buf, u8(c)) }
	}
	append(&buf, ']')

	return string(buf[:])
}

build_message :: proc(d: core.Diagnostic, allocator: mem.Allocator) -> string {
	parts := make([dynamic]string, 0, 3, allocator)
	if len(d.what) > 0 { append(&parts, d.what) }
	if len(d.why) > 0  { append(&parts, d.why) }
	if len(d.fix) > 0  { append(&parts, fmt.aprintf("Fix: %s", d.fix, allocator = allocator)) }
	return strings.join(parts[:], ". ", allocator)
}

// ==================== Position-to-Node Lookup ====================

find_expr_at_position :: proc(module: ^parser.Module, line, col: i32) -> (parser.Expr, bool) {
	// Walk all statements looking for expressions at position
	return find_in_stmts(module.body, line, col)
}

find_in_stmts :: proc(stmts: []parser.Stmt, line, col: i32) -> (parser.Expr, bool) {
	for stmt in stmts {
		if expr, ok := find_in_stmt(stmt, line, col); ok {
			return expr, true
		}
	}
	return nil, false
}

find_in_stmt :: proc(stmt: parser.Stmt, line, col: i32) -> (parser.Expr, bool) {
	#partial switch s in stmt {
	case ^parser.Assign:
		for target in s.targets {
			if e, ok := find_in_expr(target, line, col); ok { return e, true }
		}
		if e, ok := find_in_expr(s.value, line, col); ok { return e, true }

	case ^parser.Ann_Assign:
		if e, ok := find_in_expr(s.target, line, col); ok { return e, true }
		if e, ok := find_in_expr(s.annotation, line, col); ok { return e, true }
		if s.value != nil {
			if e, ok := find_in_expr(s.value, line, col); ok { return e, true }
		}

	case ^parser.Aug_Assign:
		if e, ok := find_in_expr(s.target, line, col); ok { return e, true }
		if e, ok := find_in_expr(s.value, line, col); ok { return e, true }

	case ^parser.Return_Stmt:
		if s.value != nil {
			if e, ok := find_in_expr(s.value, line, col); ok { return e, true }
		}

	case ^parser.Expr_Stmt:
		if e, ok := find_in_expr(s.value, line, col); ok { return e, true }

	case ^parser.Func_Def:
		if e, ok := find_in_stmts(s.body, line, col); ok { return e, true }

	case ^parser.Async_Func_Def:
		if e, ok := find_in_stmts(s.body, line, col); ok { return e, true }

	case ^parser.Class_Def:
		if e, ok := find_in_stmts(s.body, line, col); ok { return e, true }

	case ^parser.If_Stmt:
		if e, ok := find_in_expr(s.test, line, col); ok { return e, true }
		if e, ok := find_in_stmts(s.body, line, col); ok { return e, true }
		if e, ok := find_in_stmts(s.orelse, line, col); ok { return e, true }

	case ^parser.For_Stmt:
		if e, ok := find_in_expr(s.target, line, col); ok { return e, true }
		if e, ok := find_in_expr(s.iter, line, col); ok { return e, true }
		if e, ok := find_in_stmts(s.body, line, col); ok { return e, true }
		if e, ok := find_in_stmts(s.orelse, line, col); ok { return e, true }

	case ^parser.While_Stmt:
		if e, ok := find_in_expr(s.test, line, col); ok { return e, true }
		if e, ok := find_in_stmts(s.body, line, col); ok { return e, true }
		if e, ok := find_in_stmts(s.orelse, line, col); ok { return e, true }

	case ^parser.With_Stmt:
		if e, ok := find_in_stmts(s.body, line, col); ok { return e, true }

	case ^parser.Try_Stmt:
		if e, ok := find_in_stmts(s.body, line, col); ok { return e, true }
		for handler in s.handlers {
			if e, ok := find_in_stmts(handler.body, line, col); ok { return e, true }
		}
		if e, ok := find_in_stmts(s.orelse, line, col); ok { return e, true }
		if e, ok := find_in_stmts(s.finalbody, line, col); ok { return e, true }

	case ^parser.Assert_Stmt:
		if e, ok := find_in_expr(s.test, line, col); ok { return e, true }

	case ^parser.Delete_Stmt:
		for target in s.targets {
			if e, ok := find_in_expr(target, line, col); ok { return e, true }
		}

	case ^parser.Raise_Stmt:
		if s.exc != nil {
			if e, ok := find_in_expr(s.exc, line, col); ok { return e, true }
		}
	}

	return nil, false
}

find_in_expr :: proc(expr: parser.Expr, line, col: i32) -> (parser.Expr, bool) {
	if expr == nil { return nil, false }

	loc := expr_loc(expr)
	if !loc_contains(loc, line, col) { return nil, false }

	// Try to find a deeper match in children
	#partial switch e in expr {
	case ^parser.Call_Expr:
		if child, ok := find_in_expr(e.func, line, col); ok { return child, true }
		for arg in e.args {
			if child, ok := find_in_expr(arg, line, col); ok { return child, true }
		}

	case ^parser.Attribute_Expr:
		if child, ok := find_in_expr(e.value, line, col); ok { return child, true }

	case ^parser.Subscript_Expr:
		if child, ok := find_in_expr(e.value, line, col); ok { return child, true }
		if child, ok := find_in_expr(e.slice, line, col); ok { return child, true }

	case ^parser.Bin_Op_Expr:
		if child, ok := find_in_expr(e.left, line, col); ok { return child, true }
		if child, ok := find_in_expr(e.right, line, col); ok { return child, true }

	case ^parser.Unary_Op_Expr:
		if child, ok := find_in_expr(e.operand, line, col); ok { return child, true }

	case ^parser.Compare_Expr:
		if child, ok := find_in_expr(e.left, line, col); ok { return child, true }
		for comp in e.comparators {
			if child, ok := find_in_expr(comp, line, col); ok { return child, true }
		}

	case ^parser.Bool_Op_Expr:
		for val in e.values {
			if child, ok := find_in_expr(val, line, col); ok { return child, true }
		}

	case ^parser.If_Expr:
		if child, ok := find_in_expr(e.test, line, col); ok { return child, true }
		if child, ok := find_in_expr(e.body, line, col); ok { return child, true }
		if child, ok := find_in_expr(e.orelse, line, col); ok { return child, true }

	case ^parser.Tuple_Expr:
		for elt in e.elts {
			if child, ok := find_in_expr(elt, line, col); ok { return child, true }
		}

	case ^parser.List_Expr:
		for elt in e.elts {
			if child, ok := find_in_expr(elt, line, col); ok { return child, true }
		}

	case ^parser.Dict_Expr:
		for k in e.keys {
			if child, ok := find_in_expr(k, line, col); ok { return child, true }
		}
		for v in e.values {
			if child, ok := find_in_expr(v, line, col); ok { return child, true }
		}

	case ^parser.Set_Expr:
		for elt in e.elts {
			if child, ok := find_in_expr(elt, line, col); ok { return child, true }
		}

	case ^parser.Starred_Expr:
		if child, ok := find_in_expr(e.value, line, col); ok { return child, true }

	case ^parser.Named_Expr:
		if child, ok := find_in_expr(e.target, line, col); ok { return child, true }
		if child, ok := find_in_expr(e.value, line, col); ok { return child, true }
	}

	// This expression contains the position but no child does — it's the deepest match
	return expr, true
}

// ==================== Location Helpers ====================

expr_loc :: proc(expr: parser.Expr) -> parser.Src_Loc {
	switch e in expr {
	case ^parser.Bool_Op_Expr:    return e.loc
	case ^parser.Named_Expr:     return e.loc
	case ^parser.Bin_Op_Expr:    return e.loc
	case ^parser.Unary_Op_Expr:  return e.loc
	case ^parser.Lambda_Expr:    return e.loc
	case ^parser.If_Expr:        return e.loc
	case ^parser.Dict_Expr:      return e.loc
	case ^parser.Set_Expr:       return e.loc
	case ^parser.List_Comp:      return e.loc
	case ^parser.Set_Comp:       return e.loc
	case ^parser.Dict_Comp:      return e.loc
	case ^parser.Generator_Expr: return e.loc
	case ^parser.Await_Expr:     return e.loc
	case ^parser.Yield_Expr:     return e.loc
	case ^parser.Yield_From_Expr: return e.loc
	case ^parser.Compare_Expr:   return e.loc
	case ^parser.Call_Expr:      return e.loc
	case ^parser.Formatted_Value: return e.loc
	case ^parser.Joined_Str:     return e.loc
	case ^parser.Constant_Expr:  return e.loc
	case ^parser.Attribute_Expr: return e.loc
	case ^parser.Subscript_Expr: return e.loc
	case ^parser.Starred_Expr:   return e.loc
	case ^parser.Name_Expr:      return e.loc
	case ^parser.List_Expr:      return e.loc
	case ^parser.Tuple_Expr:     return e.loc
	case ^parser.Slice_Expr:     return e.loc
	}
	return parser.Src_Loc{}
}

loc_contains :: proc(loc: parser.Src_Loc, line, col: i32) -> bool {
	// AST lines are 1-indexed, cols are 0-indexed
	if line < loc.line || line > loc.end_line { return false }
	if line == loc.line && col < loc.col { return false }
	if line == loc.end_line && col >= loc.end_col { return false }
	return true
}

src_loc_to_range :: proc(loc: parser.Src_Loc) -> Range {
	return Range{
		start = Position{line = int(loc.line) - 1, character = int(loc.col)},
		end   = Position{line = int(loc.end_line) - 1, character = int(loc.end_col)},
	}
}

uri_to_file_path :: proc(uri: string, allocator: mem.Allocator) -> string {
	if strings.has_prefix(uri, "file://") {
		return strings.clone(uri[len("file://"):], allocator)
	}
	return strings.clone(uri, allocator)
}

file_path_to_uri :: proc(path: string, allocator: mem.Allocator) -> string {
	return fmt.aprintf("file://%s", path, allocator = allocator)
}
