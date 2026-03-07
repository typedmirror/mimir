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
	// Write helper script to temp file
	helper_path := "/tmp/mimir_ast_helper.py"
	write_err := os.write_entire_file(helper_path, transmute([]byte)HELPER_SCRIPT)
	if write_err != nil {
		return {}, Bridge_Error{"failed to write helper script to /tmp"}
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

	// Start python3 subprocess
	process, proc_err := os.process_start({
		command = {"python3", "-u", helper_path},
		stdin   = stdin_r,
		stdout  = stdout_w,
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

bridge_parse :: proc(b: ^Bridge, path: string, allocator: mem.Allocator) -> (^Module, Parse_Error) {
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
		return nil, Bridge_Error{fmt.tprintf("unexpected bridge response: %s", header)}
	}

	len_start := 3 if is_ok else 4
	body_len, parse_ok := strconv.parse_int(strings.trim_space(header[len_start:]))
	if !parse_ok {
		return nil, Bridge_Error{"invalid response length in bridge header"}
	}

	// Read body bytes
	body := make([]byte, body_len, context.temp_allocator)
	body_err := _read_exact(b.stdout_r, body)
	if body_err != nil {
		return nil, body_err
	}

	if is_err {
		return nil, _parse_error_response(body, path)
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
_parse_error_response :: proc(body: []byte, path: string) -> Parse_Error {
	val, err := json.parse(body, .JSON, true)
	if err != .None {
		return Bridge_Error{fmt.tprintf("parse error in file: %s", path)}
	}
	defer json.destroy_value(val)

	obj, is_obj := val.(json.Object)
	if !is_obj {
		return Bridge_Error{fmt.tprintf("parse error in file: %s", path)}
	}

	msg_val := obj["msg"]
	msg_str, _ := msg_val.(json.String)

	line_val := obj["line"]
	line_int, _ := line_val.(json.Integer)

	col_val := obj["col"]
	col_int, _ := col_val.(json.Integer)

	return Syntax_Error{
		msg  = fmt.tprintf("%s", msg_str),
		file = fmt.tprintf("%s", path),
		line = int(line_int),
		col  = int(col_int),
	}
}
