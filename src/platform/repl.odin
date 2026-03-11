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

// ==================== REPL State ====================

Repl_State :: struct {
	accumulated_source: strings.Builder,  // all entered lines
	prev_diag_count:    int,              // total diagnostics from last run
	prev_output_len:    int,              // stdout bytes from last execution
	in_continuation:    bool,             // multi-line input mode
	continuation_lines: strings.Builder,  // buffered continuation lines
	open_brackets:      int,              // ( [ { nesting depth
	bridge:             ^parser.Bridge,
	temp_path:          string,
	allocator:          mem.Allocator,
}

// ==================== Public API ====================

init_repl :: proc(bridge: ^parser.Bridge, allocator: mem.Allocator) -> Repl_State {
	return Repl_State{
		accumulated_source = strings.builder_make(0, 1024, allocator),
		continuation_lines = strings.builder_make(0, 256, allocator),
		bridge             = bridge,
		temp_path          = "/tmp/mimir_repl_input.py",
		allocator          = allocator,
	}
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

	// Write to temp file for parsing
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

	// Execute if no new type errors
	if !has_errors {
		repl_execute(state)
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

repl_execute :: proc(state: ^Repl_State) {
	proc_state, stdout, stderr, exec_err := os.process_exec({
		command = {"python3", state.temp_path},
	}, state.allocator)

	if exec_err != nil {
		return
	}

	output := string(stdout)

	// Show only new output (beyond previously shown)
	if len(output) > state.prev_output_len {
		new_output := output[state.prev_output_len:]
		if len(new_output) > 0 {
			fmt.print(new_output)
			if new_output[len(new_output) - 1] != '\n' {
				fmt.println()
			}
		}
	}

	if proc_state.exit_code != 0 && len(stderr) > 0 {
		err_str := strings.trim_space(string(stderr))
		// Show just the last line (the actual error message)
		last_line := err_str
		for i := len(err_str) - 1; i >= 0; i -= 1 {
			if err_str[i] == '\n' {
				last_line = err_str[i + 1:]
				break
			}
		}
		if len(last_line) > 0 {
			fmt.eprintfln("  runtime: %s", last_line)
		}
	}

	state.prev_output_len = len(output)
}

// ==================== Multi-Line Detection ====================

repl_needs_continuation :: proc(line: string) -> bool {
	trimmed := strings.trim_space(line)
	if len(trimmed) == 0 { return false }

	// Lines ending with : start a block
	if trimmed[len(trimmed) - 1] == ':' { return true }

	// Check for unclosed brackets/parens
	opens := 0
	for c in line {
		switch c {
		case '(', '[', '{': opens += 1
		case ')', ']', '}': opens -= 1
		}
	}
	return opens > 0
}

repl_update_brackets :: proc(state: ^Repl_State, line: string) {
	for c in line {
		switch c {
		case '(', '[', '{': state.open_brackets += 1
		case ')', ']', '}': state.open_brackets -= 1
		}
	}
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
