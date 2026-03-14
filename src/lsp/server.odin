package lsp

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

import "core:encoding/json"

import parser "mimir:parser"

// ==================== Server State ====================

Document :: struct {
	uri:     string,
	content: string,
	version: int,
}

Cached_Analysis :: struct {
	version: int,
	result:  Analysis_Result,
}

Server :: struct {
	bridge:         ^parser.Bridge,
	documents:      map[string]Document,
	analysis_cache: map[string]Cached_Analysis,
	initialized:    bool,
	shutdown:       bool,
	allocator:      mem.Allocator,
	read_buf:       [dynamic]u8,
}

// ==================== Public API ====================

init_server :: proc(bridge: ^parser.Bridge, allocator: mem.Allocator) -> Server {
	return Server{
		bridge         = bridge,
		documents      = make(map[string]Document, 16, allocator),
		analysis_cache = make(map[string]Cached_Analysis, 8, allocator),
		allocator      = allocator,
		read_buf       = make([dynamic]u8, 0, 4096, allocator),
	}
}

run_server :: proc(server: ^Server) {
	for {
		method, id, params, ok := read_message(server)
		if !ok { break }

		dispatch(server, method, id, params)

		if server.shutdown {
			break
		}
	}
}

// ==================== JSON-RPC Message Reading ====================

read_message :: proc(server: ^Server) -> (method: string, id: json.Value, params: json.Value, ok: bool) {
	// Read Content-Length header
	content_length := read_content_length(server) or_return

	// Read exactly content_length bytes
	clear(&server.read_buf)
	resize(&server.read_buf, content_length)

	total_read := 0
	for total_read < content_length {
		n, err := os.read(os.stdin, server.read_buf[total_read:])
		if err != nil || n == 0 {
			return "", nil, nil, false
		}
		total_read += n
	}

	// Parse JSON
	body := string(server.read_buf[:content_length])
	parsed, parse_err := json.parse(transmute([]u8)body, .JSON, true, server.allocator)
	if parse_err != nil {
		return "", nil, nil, false
	}

	obj, is_obj := parsed.(json.Object)
	if !is_obj {
		return "", nil, nil, false
	}

	// Extract method
	method_val, has_method := obj["method"]
	if has_method {
		if ms, is_str := method_val.(json.String); is_str {
			method = ms
		}
	}

	// Extract id (may be absent for notifications)
	id = obj["id"] if "id" in obj else nil

	// Extract params
	params = obj["params"] if "params" in obj else nil

	return method, id, params, true
}

read_content_length :: proc(server: ^Server) -> (int, bool) {
	// Read header lines until we get \r\n\r\n
	// Format: Content-Length: N\r\n\r\n
	header_buf: [512]u8
	pos := 0

	for pos < len(header_buf) - 1 {
		n, err := os.read(os.stdin, header_buf[pos:pos + 1])
		if err != nil || n == 0 {
			return 0, false
		}
		pos += 1

		// Check for \r\n\r\n
		if pos >= 4 &&
		   header_buf[pos - 4] == '\r' && header_buf[pos - 3] == '\n' &&
		   header_buf[pos - 2] == '\r' && header_buf[pos - 1] == '\n' {
			// Parse Content-Length from header
			header := string(header_buf[:pos - 4])
			return parse_content_length(header)
		}
	}

	return 0, false
}

parse_content_length :: proc(header: string) -> (int, bool) {
	// Find "Content-Length: " prefix
	h := header
	for line in strings.split_lines_iterator(&h) {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "Content-Length:") {
			val_str := strings.trim_space(trimmed[len("Content-Length:"):])
			length, ok := strconv.parse_int(val_str)
			if ok && length > 0 {
				return length, true
			}
		}
	}
	return 0, false
}

// ==================== JSON-RPC Response Writing ====================

send_response :: proc(server: ^Server, id: json.Value, result_json: string) {
	body: string

	// Format id
	id_str := format_json_value(id, server.allocator)

	body = fmt.aprintf(
		"{{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":%s}}",
		id_str, result_json,
		allocator = server.allocator,
	)

	send_raw(body)
}

send_error :: proc(server: ^Server, id: json.Value, code: int, message: string) {
	id_str := format_json_value(id, server.allocator)
	escaped_msg := json_escape(message, server.allocator)
	body := fmt.aprintf(
		"{{\"jsonrpc\":\"2.0\",\"id\":%s,\"error\":{{\"code\":%d,\"message\":\"%s\"}}}}",
		id_str, code, escaped_msg,
		allocator = server.allocator,
	)
	send_raw(body)
}

send_notification :: proc(server: ^Server, method: string, params_json: string) {
	body := fmt.aprintf(
		"{{\"jsonrpc\":\"2.0\",\"method\":\"%s\",\"params\":%s}}",
		method, params_json,
		allocator = server.allocator,
	)
	send_raw(body)
}

send_raw :: proc(body: string) {
	header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(body))
	os.write(os.stdout, transmute([]u8)header)
	os.write(os.stdout, transmute([]u8)body)
}

// ==================== Dispatch ====================

dispatch :: proc(server: ^Server, method: string, id: json.Value, params: json.Value) {
	switch method {
	case "initialize":
		handle_initialize(server, id, params)
	case "initialized":
		// No-op notification
	case "shutdown":
		handle_shutdown(server, id)
	case "exit":
		handle_exit(server)
	case "textDocument/didOpen":
		handle_did_open(server, params)
	case "textDocument/didChange":
		handle_did_change(server, params)
	case "textDocument/didClose":
		handle_did_close(server, params)
	case "textDocument/hover":
		handle_hover(server, id, params)
	case "textDocument/definition":
		handle_definition(server, id, params)
	case "textDocument/references":
		handle_references(server, id, params)
	case:
		// Unknown method — send method not found for requests (has id)
		if id != nil {
			send_error(server, id, -32601, "Method not found")
		}
	}
}

// ==================== JSON Helpers ====================

format_json_value :: proc(val: json.Value, allocator: mem.Allocator) -> string {
	if val == nil { return "null" }

	switch v in val {
	case json.Null:    return "null"
	case json.Integer: return fmt.aprintf("%d", v, allocator = allocator)
	case json.Float:   return fmt.aprintf("%f", v, allocator = allocator)
	case json.Boolean: return v ? "true" : "false"
	case json.String:  return fmt.aprintf("\"%s\"", v, allocator = allocator)
	case json.Array:   return "null"
	case json.Object:  return "null"
	}
	return "null"
}

json_escape :: proc(s: string, allocator: mem.Allocator) -> string {
	buf := make([dynamic]u8, 0, len(s) + 16, allocator)
	for c in s {
		switch {
		case c == '"':  append(&buf, '\\'); append(&buf, '"')
		case c == '\\': append(&buf, '\\'); append(&buf, '\\')
		case c == '\n': append(&buf, '\\'); append(&buf, 'n')
		case c == '\r': append(&buf, '\\'); append(&buf, 'r')
		case c == '\t': append(&buf, '\\'); append(&buf, 't')
		case c < 0x20:
			// Control characters U+0000..U+001F → \uXXXX
			esc := fmt.tprintf("\\u%04x", int(c))
			for b in transmute([]u8)esc {
				append(&buf, b)
			}
		case:
			// Encode rune as UTF-8 bytes (preserves multi-byte characters)
			encoded, n := utf8.encode_rune(c)
			for i := 0; i < n; i += 1 {
				append(&buf, encoded[i])
			}
		}
	}
	return string(buf[:])
}
