package lsp

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:encoding/json"

import parser  "mimir:parser"
import binder  "mimir:binder"
import checker "mimir:checker"

// ==================== Lifecycle Handlers ====================

handle_initialize :: proc(server: ^Server, id: json.Value, params: json.Value) {
	server.initialized = true

	result := `{` +
		`"capabilities":{` +
			`"textDocumentSync":{"openClose":true,"change":1},` +
			`"hoverProvider":true,` +
			`"definitionProvider":true,` +
			`"referencesProvider":true` +
		`},` +
		`"serverInfo":{"name":"mimir","version":"0.0.1-dev"}` +
	`}`

	send_response(server, id, result)
}

handle_shutdown :: proc(server: ^Server, id: json.Value) {
	send_response(server, id, "null")
	server.shutdown = true
}

handle_exit :: proc(server: ^Server) {
	// Process will exit from run_server loop
	server.shutdown = true
}

// ==================== Document Sync Handlers ====================

handle_did_open :: proc(server: ^Server, params: json.Value) {
	obj, is_obj := params.(json.Object)
	if !is_obj { return }

	td_obj, has_td := obj["textDocument"]
	if !has_td { return }
	td, td_ok := td_obj.(json.Object)
	if !td_ok { return }

	uri := get_json_string(td, "uri")
	text := get_json_string(td, "text")
	version := get_json_int(td, "version")

	if len(uri) == 0 { return }

	server.documents[uri] = Document{
		uri     = strings.clone(uri, server.allocator),
		content = strings.clone(text, server.allocator),
		version = version,
	}

	// Run analysis and publish diagnostics
	publish_diagnostics(server, uri, text)
}

handle_did_change :: proc(server: ^Server, params: json.Value) {
	obj, is_obj := params.(json.Object)
	if !is_obj { return }

	td_obj, has_td := obj["textDocument"]
	if !has_td { return }
	td, td_ok := td_obj.(json.Object)
	if !td_ok { return }

	uri := get_json_string(td, "uri")
	version := get_json_int(td, "version")

	// Full sync: contentChanges[0].text has the full document
	changes_val, has_changes := obj["contentChanges"]
	if !has_changes { return }
	changes_arr, is_arr := changes_val.(json.Array)
	if !is_arr || len(changes_arr) == 0 { return }
	change, change_ok := changes_arr[0].(json.Object)
	if !change_ok { return }

	text := get_json_string(change, "text")

	// Free old document strings before overwriting to prevent memory leak
	if old_doc, has_old := server.documents[uri]; has_old {
		delete(old_doc.uri, server.allocator)
		delete(old_doc.content, server.allocator)
	}

	server.documents[uri] = Document{
		uri     = strings.clone(uri, server.allocator),
		content = strings.clone(text, server.allocator),
		version = version,
	}

	publish_diagnostics(server, uri, text)
}

handle_did_close :: proc(server: ^Server, params: json.Value) {
	obj, is_obj := params.(json.Object)
	if !is_obj { return }

	td_obj, has_td := obj["textDocument"]
	if !has_td { return }
	td, td_ok := td_obj.(json.Object)
	if !td_ok { return }

	uri := get_json_string(td, "uri")

	// Free the Document's cloned strings before removing the entry
	if old_doc, has_old := server.documents[uri]; has_old {
		delete(old_doc.uri, server.allocator)
		delete(old_doc.content, server.allocator)
	}
	delete_key(&server.documents, uri)
	delete_key(&server.analysis_cache, uri)

	// Clear diagnostics for this file
	diags_json := fmt.aprintf(
		"{{\"uri\":\"%s\",\"diagnostics\":[]}}",
		json_escape(uri, server.allocator),
		allocator = server.allocator,
	)
	send_notification(server, "textDocument/publishDiagnostics", diags_json)
}

// ==================== Feature Handlers ====================

handle_hover :: proc(server: ^Server, id: json.Value, params: json.Value) {
	uri, line, col := extract_text_document_position(params, server.allocator)
	if len(uri) == 0 {
		send_response(server, id, "null")
		return
	}

	doc, has_doc := server.documents[uri]
	if !has_doc {
		send_response(server, id, "null")
		return
	}

	// Use cached analysis if available (avoids full re-analysis on every hover)
	result := get_cached_analysis(server, uri, doc.content, doc.version)
	if !result.ok {
		send_response(server, id, "null")
		return
	}

	// LSP positions are 0-indexed; AST positions are 1-indexed lines, 0-indexed cols
	ast_line := i32(line + 1)
	ast_col := i32(col)

	// Find the expression at position
	expr, found := find_expr_at_position(result.module, ast_line, ast_col)
	if !found {
		send_response(server, id, "null")
		return
	}

	// Get type info
	type_str := ""

	// First try: Name_Expr → refs → symbol_types
	if name, is_name := expr.(^parser.Name_Expr); is_name {
		if sym_id, ref_ok := binder.get_ref(&result.bind_result, rawptr(name)); ref_ok {
			if t, t_ok := result.check_result.symbol_types[sym_id]; t_ok && t != checker.TYPE_UNKNOWN {
				type_str = checker.type_to_string(&result.check_result.registry, t)
			}
		}
	}

	// Second try: expr_types
	if len(type_str) == 0 {
		ptr := checker.expr_to_rawptr(expr)
		if t, ok := result.check_result.expr_types[ptr]; ok && t != checker.TYPE_UNKNOWN {
			type_str = checker.type_to_string(&result.check_result.registry, t)
		}
	}

	if len(type_str) == 0 {
		send_response(server, id, "null")
		return
	}

	loc := expr_loc(expr)
	r := src_loc_to_range(loc)

	escaped_type := json_escape(type_str, server.allocator)
	hover_json := fmt.aprintf(
		"{{\"contents\":{{\"kind\":\"markdown\",\"value\":\"```python\\n%s\\n```\"}},\"range\":{{\"start\":{{\"line\":%d,\"character\":%d}},\"end\":{{\"line\":%d,\"character\":%d}}}}}}",
		escaped_type,
		r.start.line, r.start.character,
		r.end.line, r.end.character,
		allocator = server.allocator,
	)
	send_response(server, id, hover_json)
}

handle_definition :: proc(server: ^Server, id: json.Value, params: json.Value) {
	uri, line, col := extract_text_document_position(params, server.allocator)
	if len(uri) == 0 {
		send_response(server, id, "null")
		return
	}

	doc, has_doc := server.documents[uri]
	if !has_doc {
		send_response(server, id, "null")
		return
	}

	result := get_cached_analysis(server, uri, doc.content, doc.version)
	if !result.ok {
		send_response(server, id, "null")
		return
	}

	ast_line := i32(line + 1)
	ast_col := i32(col)

	expr, found := find_expr_at_position(result.module, ast_line, ast_col)
	if !found {
		send_response(server, id, "null")
		return
	}

	// Must be a Name_Expr to look up definition
	name, is_name := expr.(^parser.Name_Expr)
	if !is_name {
		send_response(server, id, "null")
		return
	}

	sym_id, ref_ok := binder.get_ref(&result.bind_result, rawptr(name))
	if !ref_ok {
		send_response(server, id, "null")
		return
	}

	sym := binder.result_get_symbol(&result.bind_result, sym_id)
	if sym == nil {
		send_response(server, id, "null")
		return
	}

	def_loc := sym.def_loc
	def_range := src_loc_to_range(def_loc)

	escaped_uri := json_escape(uri, server.allocator)
	loc_json := fmt.aprintf(
		"{{\"uri\":\"%s\",\"range\":{{\"start\":{{\"line\":%d,\"character\":%d}},\"end\":{{\"line\":%d,\"character\":%d}}}}}}",
		escaped_uri,
		def_range.start.line, def_range.start.character,
		def_range.end.line, def_range.end.character,
		allocator = server.allocator,
	)
	send_response(server, id, loc_json)
}

handle_references :: proc(server: ^Server, id: json.Value, params: json.Value) {
	uri, line, col := extract_text_document_position(params, server.allocator)
	if len(uri) == 0 {
		send_response(server, id, "[]")
		return
	}

	doc, has_doc := server.documents[uri]
	if !has_doc {
		send_response(server, id, "[]")
		return
	}

	result := get_cached_analysis(server, uri, doc.content, doc.version)
	if !result.ok {
		send_response(server, id, "[]")
		return
	}

	ast_line := i32(line + 1)
	ast_col := i32(col)

	expr, found := find_expr_at_position(result.module, ast_line, ast_col)
	if !found {
		send_response(server, id, "[]")
		return
	}

	name, is_name := expr.(^parser.Name_Expr)
	if !is_name {
		send_response(server, id, "[]")
		return
	}

	target_sym_id, ref_ok := binder.get_ref(&result.bind_result, rawptr(name))
	if !ref_ok {
		send_response(server, id, "[]")
		return
	}

	// Scan all refs to find entries pointing to the same symbol
	escaped_uri := json_escape(uri, server.allocator)
	locations := make([dynamic]string, 0, 16, server.allocator)

	for node_ptr, sym_id in result.bind_result.refs {
		if sym_id != target_sym_id { continue }

		// Get the AST node's location
		// The node_ptr points to a Name_Expr
		name_expr := cast(^parser.Name_Expr)node_ptr
		ref_range := src_loc_to_range(name_expr.loc)

		loc_str := fmt.aprintf(
			"{{\"uri\":\"%s\",\"range\":{{\"start\":{{\"line\":%d,\"character\":%d}},\"end\":{{\"line\":%d,\"character\":%d}}}}}}",
			escaped_uri,
			ref_range.start.line, ref_range.start.character,
			ref_range.end.line, ref_range.end.character,
			allocator = server.allocator,
		)
		append(&locations, loc_str)
	}

	// Definition is already included via binder refs (both Load and Store Name_Exprs are registered)

	result_json := fmt.aprintf("[%s]", strings.join(locations[:], ",", server.allocator), allocator = server.allocator)
	send_response(server, id, result_json)
}

// ==================== Analysis Cache ====================

// get_cached_analysis returns a cached analysis result if the version matches,
// or re-analyzes and caches the result.
get_cached_analysis :: proc(server: ^Server, uri: string, content: string, version: int) -> Analysis_Result {
	if cached, ok := server.analysis_cache[uri]; ok {
		if cached.version == version {
			return cached.result
		}
	}
	// Cache miss — run full analysis and cache
	result := analyze_document(server, uri, content)
	server.analysis_cache[uri] = Cached_Analysis{version = version, result = result}
	return result
}

// ==================== Diagnostics Publishing ====================

publish_diagnostics :: proc(server: ^Server, uri: string, content: string) {
	doc, has_doc := server.documents[uri]
	version := doc.version if has_doc else 0

	result := get_cached_analysis(server, uri, content, version)

	diags_json := diagnostics_to_json(result.all_diags[:], uri, server.allocator)
	escaped_uri := json_escape(uri, server.allocator)

	params_json := fmt.aprintf(
		"{{\"uri\":\"%s\",\"diagnostics\":%s}}",
		escaped_uri, diags_json,
		allocator = server.allocator,
	)

	send_notification(server, "textDocument/publishDiagnostics", params_json)
}

// ==================== JSON Helpers ====================

get_json_string :: proc(obj: json.Object, key: string) -> string {
	if val, ok := obj[key]; ok {
		if s, is_str := val.(json.String); is_str {
			return s
		}
	}
	return ""
}

get_json_int :: proc(obj: json.Object, key: string) -> int {
	if val, ok := obj[key]; ok {
		#partial switch v in val {
		case json.Integer: return int(v)
		case json.Float:   return int(v)
		}
	}
	return 0
}

extract_text_document_position :: proc(params: json.Value, allocator: mem.Allocator) -> (uri: string, line: int, col: int) {
	obj, is_obj := params.(json.Object)
	if !is_obj { return "", 0, 0 }

	td_val, has_td := obj["textDocument"]
	if !has_td { return "", 0, 0 }
	td, td_ok := td_val.(json.Object)
	if !td_ok { return "", 0, 0 }

	uri = get_json_string(td, "uri")

	pos_val, has_pos := obj["position"]
	if !has_pos { return uri, 0, 0 }
	pos, pos_ok := pos_val.(json.Object)
	if !pos_ok { return uri, 0, 0 }

	line = get_json_int(pos, "line")
	col = get_json_int(pos, "character")

	return uri, line, col
}
