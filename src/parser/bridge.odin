package parser

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"

HELPER_SCRIPT := string(#load("../../data/ast_helper.py"))

Bridge :: struct {
	process:     os.Process,
	stdin_w:     ^os.File,
	stdout_r:    ^os.File,
	helper_path: string,
}

bridge_start :: proc() -> (Bridge, Parse_Error) {
	// Write helper script to temp file with PID-unique name
	pid := os.get_pid()
	helper_path := fmt.aprintf("/tmp/mimir_ast_helper_%d.py", pid)
	write_err := os.write_entire_file(helper_path, transmute([]byte)HELPER_SCRIPT)
	if write_err != nil {
		return {}, Bridge_Error{"failed to write helper script"}
	}

	// Create pipes for child stdin/stdout
	stdin_r, stdin_w, pipe_err1 := os.pipe()
	if pipe_err1 != nil {
		return {}, Bridge_Error{"failed to create stdin pipe"}
	}

	stdout_r, stdout_w, pipe_err2 := os.pipe()
	if pipe_err2 != nil {
		os.close(stdin_r)
		os.close(stdin_w)
		return {}, Bridge_Error{"failed to create stdout pipe"}
	}

	// Start python3 subprocess (stderr inherits parent terminal for error visibility)
	process, proc_err := os.process_start({
		command = {"python3", "-u", helper_path},
		stdin   = stdin_r,
		stdout  = stdout_w,
		stderr  = os.stderr,
	})
	if proc_err != nil {
		os.close(stdin_r)
		os.close(stdin_w)
		os.close(stdout_r)
		os.close(stdout_w)
		return {}, Bridge_Error{"failed to start python3 — is python3 installed?"}
	}

	// Close the ends the parent doesn't use
	os.close(stdin_r)
	os.close(stdout_w)

	return Bridge{
		process     = process,
		stdin_w     = stdin_w,
		stdout_r    = stdout_r,
		helper_path = helper_path,
	}, nil
}

// Native parser entry point: read file → tokenize → parse → AST.
parse_native :: proc(path: string, allocator: mem.Allocator) -> (^Module, Parse_Error) {
	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		return nil, Bridge_Error{fmt.aprintf("failed to read file: %s", path, allocator = allocator)}
	}
	source := string(data)

	tokens, tok_err := tokenize(source, allocator)
	if tok_err != nil {
		// Add file path to error
		#partial switch &e in tok_err {
		case Syntax_Error:
			e.file = path
		}
		return nil, tok_err
	}

	ctx := Parser_Context{
		tokens    = tokens,
		pos       = 0,
		allocator = allocator,
		file      = path,
	}

	mod := parse_module_native(&ctx)
	return mod, nil
}

// Quick check if source contains f-strings.
// Tracks comment/string context to avoid false positives on `# f"..."` or `"f\""`.
_source_has_fstrings :: proc(source: string) -> bool {
	i := 0
	for i < len(source) {
		c := source[i]

		// Skip comments (# to end of line)
		if c == '#' {
			for i < len(source) && source[i] != '\n' { i += 1 }
			continue
		}

		// Skip string literals (to avoid matching f" inside strings)
		if c == '\'' || c == '"' {
			i = _skip_string_literal(source, i)
			continue
		}

		// Check for f-string prefix: f", f', F", F', rf", fr", RF", FR", etc.
		if (c == 'f' || c == 'F') && i + 1 < len(source) && (source[i + 1] == '"' || source[i + 1] == '\'') {
			return true
		}
		if (c == 'r' || c == 'R') && i + 2 < len(source) && (source[i + 1] == 'f' || source[i + 1] == 'F') && (source[i + 2] == '"' || source[i + 2] == '\'') {
			return true
		}
		if (c == 'f' || c == 'F') && i + 2 < len(source) && (source[i + 1] == 'r' || source[i + 1] == 'R') && (source[i + 2] == '"' || source[i + 2] == '\'') {
			return true
		}

		i += 1
	}
	return false
}

// Skip past a string literal starting at position i (on the opening quote).
_skip_string_literal :: proc(source: string, start: int) -> int {
	i := start
	if i >= len(source) { return i }
	quote := source[i]
	// Triple-quoted?
	if i + 2 < len(source) && source[i + 1] == quote && source[i + 2] == quote {
		i += 3
		for i < len(source) {
			if source[i] == '\\' { i += 2; continue }
			if source[i] == quote && i + 2 < len(source) && source[i + 1] == quote && source[i + 2] == quote {
				return i + 3
			}
			i += 1
		}
		return i
	}
	// Single-quoted
	i += 1
	for i < len(source) && source[i] != '\n' {
		if source[i] == '\\' { i += 2; continue }
		if source[i] == quote { return i + 1 }
		i += 1
	}
	return i
}

// If true, skip native parser and always use CPython bridge.
use_legacy_parser := false

bridge_parse :: proc(b: ^Bridge, path: string, allocator: mem.Allocator) -> (^Module, Parse_Error) {
	// Try native parser first (unless legacy mode is forced)
	if !use_legacy_parser {
		mod, err := parse_native(path, allocator)
		if err == nil && mod != nil {
			return mod, nil
		}
		// Fall through to CPython bridge on failure
	}

	// Send PARSE request
	request := fmt.tprintf("PARSE %s\n", path)
	_, write_err := os.write(b.stdin_w, transmute([]byte)request)
	if write_err != nil {
		return nil, Bridge_Error{"failed to write to bridge stdin"}
	}

	// Read response header line
	header_buf: [4096]byte
	header, header_err := _read_line(b.stdout_r, header_buf[:])
	if header_err != nil {
		return nil, header_err
	}

	// Parse header: "OK <len>" or "ERR <len>"
	is_ok := strings.has_prefix(header, "OK ")
	is_err := strings.has_prefix(header, "ERR ")

	if !is_ok && !is_err {
		return nil, Bridge_Error{fmt.aprintf("unexpected bridge response: %s", header, allocator = allocator)}
	}

	len_start := 3 if is_ok else 4
	body_len, parse_ok := strconv.parse_int(strings.trim_space(header[len_start:]))
	if !parse_ok || body_len < 0 {
		return nil, Bridge_Error{"invalid response length in bridge header"}
	}
	if body_len > 100_000_000 {
		return nil, Bridge_Error{"bridge response body too large (>100MB)"}
	}

	// Read body bytes
	body := make([]byte, body_len, context.temp_allocator)
	body_err := _read_exact(b.stdout_r, body)
	if body_err != nil {
		return nil, body_err
	}

	if is_err {
		return nil, _parse_error_response(body, path, allocator)
	}

	// Convert JSON to AST
	return json_to_module(body, allocator)
}

bridge_stop :: proc(b: ^Bridge) {
	os.write(b.stdin_w, transmute([]byte)string("QUIT\n"))
	os.close(b.stdin_w)
	os.close(b.stdout_r)
	_, _ = os.process_wait(b.process)
	os.remove(b.helper_path)
}

// ==================== Internal Helpers ====================

// Read bytes until newline, return the line without the newline.
@(private = "file")
_read_line :: proc(f: ^os.File, buf: []byte) -> (string, Parse_Error) {
	n := 0
	for n < len(buf) {
		bytes_read, err := os.read(f, buf[n:n + 1])
		if err != nil {
			return "", Bridge_Error{"failed to read from bridge stdout"}
		}
		if bytes_read == 0 {
			break
		}
		if buf[n] == '\n' {
			return string(buf[:n]), nil
		}
		n += 1
	}
	if n == 0 {
		return "", Bridge_Error{"bridge process closed unexpectedly"}
	}
	return string(buf[:n]), nil
}

// Read exactly len(buf) bytes.
@(private = "file")
_read_exact :: proc(f: ^os.File, buf: []byte) -> Parse_Error {
	total := 0
	for total < len(buf) {
		n, err := os.read(f, buf[total:])
		if err != nil {
			return Bridge_Error{"failed to read response body from bridge"}
		}
		if n == 0 {
			return Bridge_Error{"unexpected EOF reading bridge response body"}
		}
		total += n
	}
	return nil
}

// Parse an error response JSON into a Syntax_Error.
@(private = "file")
_parse_error_response :: proc(body: []byte, path: string, allocator: mem.Allocator) -> Parse_Error {
	val, err := json.parse(body, .JSON, true)
	if err != .None {
		return Bridge_Error{fmt.aprintf("parse error in file: %s", path, allocator = allocator)}
	}
	defer json.destroy_value(val)

	obj, is_obj := val.(json.Object)
	if !is_obj {
		return Bridge_Error{fmt.aprintf("parse error in file: %s", path, allocator = allocator)}
	}

	msg_val := obj["msg"]
	msg_str, _ := msg_val.(json.String)

	line_val := obj["line"]
	line_int, _ := line_val.(json.Integer)

	col_val := obj["col"]
	col_int, _ := col_val.(json.Integer)

	return Syntax_Error{
		msg  = strings.clone(msg_str, allocator),
		file = strings.clone(path, allocator),
		line = int(line_int),
		col  = int(col_int),
	}
}
