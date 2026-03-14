package platform

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

import parser  "mimir:parser"
import binder  "mimir:binder"
import flow    "mimir:flow"
import checker "mimir:checker"
import core    "mimir:core"

REPL_EXEC_SCRIPT := string(#load("../../data/repl_exec.py"))

// ==================== REPL State ====================

Repl_State :: struct {
	accumulated_source: strings.Builder,  // all entered lines (for type checking)
	prev_diag_count:    int,              // total diagnostics from last run
	in_continuation:    bool,             // multi-line input mode
	continuation_lines: strings.Builder,  // buffered continuation lines
	open_brackets:      int,              // ( [ { nesting depth
	bridge:             ^parser.Bridge,
	temp_path:          string,
	allocator:          mem.Allocator,
	// Persistent Python execution process
	exec_proc:          os.Process,
	exec_stdin:         ^os.File,
	exec_stdout:        ^os.File,
	exec_running:       bool,
	exec_script_path:   string,
}

// Sentinels include \x00 to prevent injection via normal Python input/output
EXEC_SENTINEL :: "\x00__MIMIR_EXEC__\x00"
DONE_SENTINEL :: "\x00__MIMIR_DONE__\x00"

// ==================== Public API ====================

init_repl :: proc(bridge: ^parser.Bridge, allocator: mem.Allocator) -> Repl_State {
	pid := os.get_pid()
	state := Repl_State{
		accumulated_source = strings.builder_make(0, 1024, allocator),
		continuation_lines = strings.builder_make(0, 256, allocator),
		bridge             = bridge,
		temp_path          = fmt.aprintf("/tmp/mimir_repl_%d.py", pid, allocator = allocator),
		exec_script_path   = fmt.aprintf("/tmp/mimir_repl_exec_%d.py", pid, allocator = allocator),
		allocator          = allocator,
	}

	// Start persistent Python execution subprocess
	write_err := os.write_entire_file(state.exec_script_path, transmute([]byte)REPL_EXEC_SCRIPT)
	if write_err != nil {
		fmt.eprintln("repl: warning: could not start execution subprocess")
		return state
	}

	stdin_r, stdin_w, pipe1_err := os.pipe()
	if pipe1_err != nil {
		return state
	}
	stdout_r, stdout_w, pipe2_err := os.pipe()
	if pipe2_err != nil {
		os.close(stdin_r)
		os.close(stdin_w)
		return state
	}

	py_process, proc_err := os.process_start({
		command = {"python3", "-u", state.exec_script_path},
		stdin   = stdin_r,
		stdout  = stdout_w,
		stderr  = stdout_w,
	})
	if proc_err != nil {
		os.close(stdin_r)
		os.close(stdin_w)
		os.close(stdout_r)
		os.close(stdout_w)
		return state
	}

	// Close child-side pipe ends
	os.close(stdin_r)
	os.close(stdout_w)

	state.exec_proc = py_process
	state.exec_stdin = stdin_w
	state.exec_stdout = stdout_r
	state.exec_running = true

	return state
}

run_repl :: proc(state: ^Repl_State) {
	fmt.println("mimir repl \u2014 type-aware Python REPL")
	fmt.println("Type Python code. See types instantly. Ctrl+D to exit.")
	fmt.println()

	for {
		if state.in_continuation {
			fmt.print("... ")
		} else {
			fmt.print(">>> ")
		}

		line, ok := repl_read_line(state.allocator)
		if !ok {
			fmt.println()
			break
		}

		trimmed := strings.trim_space(line)

		// Exit commands
		if !state.in_continuation && (trimmed == "exit()" || trimmed == "quit()") {
			break
		}

		// Handle continuation mode
		if state.in_continuation {
			if trimmed == "" && state.open_brackets <= 0 {
				state.in_continuation = false
				block := strings.clone(strings.to_string(state.continuation_lines), state.allocator)
				strings.builder_reset(&state.continuation_lines)
				state.open_brackets = 0
				repl_process_input(state, block)
			} else {
				strings.write_string(&state.continuation_lines, line)
				strings.write_byte(&state.continuation_lines, '\n')
				repl_update_brackets(state, line)
			}
			continue
		}

		// Check if line starts continuation
		if repl_needs_continuation(line) {
			state.in_continuation = true
			state.open_brackets = 0
			strings.builder_reset(&state.continuation_lines)
			strings.write_string(&state.continuation_lines, line)
			strings.write_byte(&state.continuation_lines, '\n')
			repl_update_brackets(state, line)
			continue
		}

		if trimmed == "" { continue }

		repl_process_input(state, line)
	}

	// Clean up persistent Python process
	repl_stop_exec(state)
}

// ==================== Input Reading ====================

repl_read_line :: proc(allocator: mem.Allocator) -> (string, bool) {
	buf: [4096]byte
	n := 0
	for n < len(buf) - 1 {
		bytes_read, err := os.read(os.stdin, buf[n:n + 1])
		if err != nil || bytes_read == 0 {
			if n > 0 {
				return strings.clone(string(buf[:n]), allocator), true
			}
			return "", false
		}
		if buf[n] == '\n' {
			return strings.clone(string(buf[:n]), allocator), true
		}
		n += 1
	}
	return strings.clone(string(buf[:n]), allocator), true
}

// ==================== Input Processing ====================

repl_process_input :: proc(state: ^Repl_State, input: string) {
	prev_len := strings.builder_len(state.accumulated_source)

	// Append new input with trailing newline
	strings.write_string(&state.accumulated_source, input)
	if len(input) == 0 || input[len(input) - 1] != '\n' {
		strings.write_byte(&state.accumulated_source, '\n')
	}

	source := strings.to_string(state.accumulated_source)

	// Write full accumulated source to temp file for parsing
	write_err := os.write_entire_file(state.temp_path, transmute([]byte)source)
	if write_err != nil {
		fmt.eprintln("repl: failed to write temp file")
		resize(&state.accumulated_source.buf, prev_len)
		return
	}

	// Parse
	module, parse_err := parser.bridge_parse(state.bridge, state.temp_path, state.allocator)
	if parse_err != nil {
		#partial switch e in parse_err {
		case parser.Syntax_Error:
			fmt.eprintfln("  syntax error: %s", e.msg)
		case parser.Bridge_Error:
			fmt.eprintfln("  error: %s", e.msg)
		}
		resize(&state.accumulated_source.buf, prev_len)
		return
	}

	// Bind
	bind_result := binder.bind(module, "<repl>", state.allocator)

	// Flow analyze
	flow_result := flow.analyze(module, &bind_result, "<repl>", state.allocator)

	// Type check
	check_result := checker.check(module, &bind_result, &flow_result, "<repl>", state.allocator)

	// Count total diagnostics
	total_diags := len(bind_result.diagnostics) + len(flow_result.diagnostics) + len(check_result.diagnostics)

	// Display NEW diagnostics only (beyond previous count)
	has_errors := false
	idx := 0

	for d in bind_result.diagnostics {
		if idx >= state.prev_diag_count {
			repl_print_diagnostic(d)
			if d.severity == .Error { has_errors = true }
		}
		idx += 1
	}
	for d in flow_result.diagnostics {
		if idx >= state.prev_diag_count {
			repl_print_diagnostic(d)
			if d.severity == .Error { has_errors = true }
		}
		idx += 1
	}
	for d in check_result.diagnostics {
		if idx >= state.prev_diag_count {
			repl_print_diagnostic(d)
			if d.severity == .Error { has_errors = true }
		}
		idx += 1
	}

	state.prev_diag_count = total_diags

	// Display type info for the last statement
	if len(module.body) > 0 {
		last_stmt := module.body[len(module.body) - 1]
		repl_display_type(last_stmt, &check_result)
	}

	// Execute ONLY the new input (not accumulated) if no type errors
	if !has_errors {
		repl_execute(state, input)
	}
}

// ==================== Type Display ====================

repl_display_type :: proc(stmt: parser.Stmt, result: ^checker.Check_Result) {
	#partial switch s in stmt {
	case ^parser.Assign:
		if s.value != nil {
			val_type, found := result.expr_types[checker.expr_to_rawptr(s.value)]
			if found && val_type != checker.TYPE_UNKNOWN {
				for target in s.targets {
					#partial switch t in target {
					case ^parser.Name_Expr:
						fmt.printfln("# %s: %s", t.id, checker.type_to_string(&result.registry, val_type))
					}
				}
			}
		}
	case ^parser.Ann_Assign:
		if s.value != nil {
			val_type, found := result.expr_types[checker.expr_to_rawptr(s.value)]
			if found && val_type != checker.TYPE_UNKNOWN {
				#partial switch t in s.target {
				case ^parser.Name_Expr:
					fmt.printfln("# %s: %s", t.id, checker.type_to_string(&result.registry, val_type))
				}
			}
		}
	case ^parser.Expr_Stmt:
		if s.value != nil {
			val_type, found := result.expr_types[checker.expr_to_rawptr(s.value)]
			if found && val_type != checker.TYPE_NONE && val_type != checker.TYPE_UNKNOWN {
				fmt.printfln("# type: %s", checker.type_to_string(&result.registry, val_type))
			}
		}
	}
}

// ==================== Execution ====================

repl_execute :: proc(state: ^Repl_State, input: string) {
	if !state.exec_running { return }

	// Send only the NEW input to the persistent Python process
	code := input
	if len(code) == 0 { return }

	os.write(state.exec_stdin, transmute([]byte)code)
	// Ensure trailing newline before sentinel
	if code[len(code) - 1] != '\n' {
		os.write(state.exec_stdin, transmute([]byte)string("\n"))
	}
	os.write(state.exec_stdin, transmute([]byte)string(EXEC_SENTINEL))
	os.write(state.exec_stdin, transmute([]byte)string("\n"))

	// Read output until DONE sentinel
	output := repl_read_until_sentinel(state.exec_stdout, DONE_SENTINEL, state.allocator)
	if len(output) > 0 {
		fmt.print(output)
		if output[len(output) - 1] != '\n' {
			fmt.println()
		}
	}
}

repl_stop_exec :: proc(state: ^Repl_State) {
	if !state.exec_running { return }
	os.close(state.exec_stdin)
	os.close(state.exec_stdout)
	_, _ = os.process_wait(state.exec_proc)
	os.remove(state.exec_script_path)
	os.remove(state.temp_path)
	state.exec_running = false
}

// Read lines from pipe until sentinel line, return everything before it.
repl_read_until_sentinel :: proc(f: ^os.File, sentinel: string, allocator: mem.Allocator) -> string {
	result: strings.Builder
	strings.builder_init(&result, 0, 256, allocator)
	line_buf: [4096]byte
	pos := 0

	for {
		bytes_read, err := os.read(f, line_buf[pos:pos + 1])
		if err != nil || bytes_read == 0 {
			// Process died or pipe closed
			break
		}
		if line_buf[pos] == '\n' {
			line := string(line_buf[:pos])
			if line == sentinel {
				break
			}
			strings.write_string(&result, line)
			strings.write_byte(&result, '\n')
			pos = 0
		} else {
			pos += 1
			if pos >= len(line_buf) - 1 {
				// Line too long — flush what we have
				strings.write_string(&result, string(line_buf[:pos]))
				pos = 0
			}
		}
	}

	return strings.to_string(result)
}

// ==================== Multi-Line Detection ====================

repl_needs_continuation :: proc(line: string) -> bool {
	trimmed := strings.trim_space(line)
	if len(trimmed) == 0 { return false }

	// Lines ending with : start a block
	if trimmed[len(trimmed) - 1] == ':' { return true }

	// Check for unclosed brackets/parens (skip brackets inside strings)
	return repl_count_brackets(line) > 0
}

repl_update_brackets :: proc(state: ^Repl_State, line: string) {
	state.open_brackets += repl_count_brackets(line)
}

// Count net open brackets in a line, skipping brackets inside string literals and comments.
repl_count_brackets :: proc(line: string) -> int {
	opens := 0
	in_string: u8 = 0  // 0 = not in string, '\'' or '"' = quote char
	escaped := false
	for i := 0; i < len(line); i += 1 {
		c := line[i]
		if escaped {
			escaped = false
			continue
		}
		if c == '\\' && in_string != 0 {
			escaped = true
			continue
		}
		if in_string != 0 {
			if c == in_string {
				in_string = 0
			}
			continue
		}
		// Not in string
		if c == '#' { break }  // rest of line is comment
		if c == '\'' || c == '"' {
			in_string = c
			continue
		}
		switch c {
		case '(', '[', '{': opens += 1
		case ')', ']', '}': opens -= 1
		}
	}
	return opens
}

// ==================== Helpers ====================

repl_print_diagnostic :: proc(d: core.Diagnostic) {
	severity_str: string
	switch d.severity {
	case .Error:       severity_str = "error"
	case .Warning:     severity_str = "warning"
	case .Security:    severity_str = "security"
	case .Performance: severity_str = "performance"
	case .Suggestion:  severity_str = "suggestion"
	case .Info:        severity_str = "info"
	}

	fmt.printfln("  %s[%s]: %s", severity_str, d.code, d.what)
	if len(d.fix) > 0 {
		fmt.printfln("    fix: %s", d.fix)
	}
}
