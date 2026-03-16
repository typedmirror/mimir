package platform

import "core:fmt"
import "core:mem"
import "core:strings"

import parser "mimir:parser"

// ==================== Configuration ====================

Quote_Style :: enum u8 {
	Double,
	Single,
}

Format_Config :: struct {
	line_length:    int,
	indent_width:   int,
	quote_style:    Quote_Style,
	trailing_comma: bool,
	check_only:     bool,
	show_diff:      bool,
}

default_format_config :: proc() -> Format_Config {
	return Format_Config{
		line_length    = 88,
		indent_width   = 4,
		quote_style    = .Double,
		trailing_comma = true,
	}
}

// ==================== Entry Point ====================

// Format a Python source file using AST-guided transformations.
// Returns the formatted source and whether it changed.
format_file :: proc(
	source: string,
	module: ^parser.Module,
	config: ^Format_Config,
	allocator: mem.Allocator,
) -> (result: string, changed: bool) {
	if len(source) == 0 { return "", false }

	// Split source into lines (preserving line endings for diffing)
	lines := split_lines(source, allocator)
	if len(lines) == 0 { return source, false }

	// Collect AST structural info for formatting decisions
	info := collect_structure(module, allocator)

	// Pass 1: Trailing whitespace + indentation normalization
	any_changed := false
	for i := 0; i < len(lines); i += 1 {
		new_line := normalize_line(lines[i], config, allocator)
		if new_line != lines[i] {
			lines[i] = new_line
			any_changed = true
		}
	}

	// Pass 2: Quote normalization (before blank lines — AST locations still valid)
	for &loc in info.string_locs {
		if loc.line > 0 && loc.line <= len(lines) {
			new_line := normalize_quotes(lines[loc.line - 1], loc, config, allocator)
			if new_line != lines[loc.line - 1] {
				lines[loc.line - 1] = new_line
				any_changed = true
			}
		}
	}

	// Pass 3: Trailing comma insertion (before blank lines — AST locations still valid)
	if config.trailing_comma {
		for &tc in info.trailing_comma_locs {
			if tc.line > 0 && tc.line <= len(lines) {
				new_line := insert_trailing_comma(lines[tc.line - 1], tc, allocator)
				if new_line != lines[tc.line - 1] {
					lines[tc.line - 1] = new_line
					any_changed = true
				}
			}
		}
	}

	// Pass 4: Line wrapping (text-based, adds lines — must run before blank line normalization)
	if config.line_length > 0 {
		wrapped_lines, wrap_changed := wrap_long_lines(lines, config, allocator)
		if wrap_changed {
			lines = wrapped_lines
			any_changed = true
		}
	}

	// Pass 5: Blank line normalization (last — may shift line numbers)
	lines, any_changed = normalize_blank_lines(lines, &info, any_changed, allocator)

	// Pass 6: Convergence re-wrap — earlier passes (trailing comma, quote normalization)
	// may have pushed lines over the limit. Join multi-line constructs and re-wrap.
	if config.line_length > 0 {
		for _ in 0..<3 {
			joined_lines, join_changed := join_and_rewrap(lines, config, allocator)
			if !join_changed { break }
			lines = joined_lines
			any_changed = true
		}
	}

	// Join lines and ensure trailing newline
	joined := join_lines(lines, allocator)
	if len(joined) > 0 && joined[len(joined) - 1] != '\n' {
		buf := make([dynamic]u8, 0, len(joined) + 1, allocator)
		for c in joined { append(&buf, u8(c)) }
		append(&buf, '\n')
		joined = string(buf[:])
		any_changed = true
	}
	// Remove multiple trailing newlines
	for len(joined) > 1 && joined[len(joined) - 1] == '\n' && joined[len(joined) - 2] == '\n' {
		joined = joined[:len(joined) - 1]
		any_changed = true
	}

	if !any_changed { return source, false }
	return joined, true
}

// ==================== Structural Analysis ====================

String_Loc :: struct {
	line:       int,    // 1-indexed
	col:        int,    // 0-indexed byte offset in line
	end_col:    int,    // 0-indexed end byte offset
	is_fstring: bool,
	is_triple:  bool,
	is_bytes:   bool,
}

Trailing_Comma_Loc :: struct {
	line:      int,    // 1-indexed line of last element
	end_col:   int,    // byte offset after last element
}

Struct_Info :: struct {
	// Lines that start a top-level function or class def (1-indexed)
	toplevel_def_lines: [dynamic]int,
	// Lines that start a method def inside a class (1-indexed)
	method_def_lines:   [dynamic]int,
	// String literal locations for quote normalization
	string_locs:        [dynamic]String_Loc,
	// Locations where trailing commas should be inserted
	trailing_comma_locs: [dynamic]Trailing_Comma_Loc,
}

collect_structure :: proc(module: ^parser.Module, allocator: mem.Allocator) -> Struct_Info {
	info: Struct_Info
	info.toplevel_def_lines = make([dynamic]int, 0, 16, allocator)
	info.method_def_lines = make([dynamic]int, 0, 16, allocator)
	info.string_locs = make([dynamic]String_Loc, 0, 32, allocator)
	info.trailing_comma_locs = make([dynamic]Trailing_Comma_Loc, 0, 16, allocator)

	// Collect top-level defs
	for stmt in module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			line := int(s.loc.line)
			// Account for decorators — use first decorator line if present
			if len(s.decorator_list) > 0 {
				first_dec := get_expr_line(s.decorator_list[0])
				if first_dec > 0 { line = first_dec }
			}
			append(&info.toplevel_def_lines, line)
		case ^parser.Async_Func_Def:
			line := int(s.loc.line)
			if len(s.decorator_list) > 0 {
				first_dec := get_expr_line(s.decorator_list[0])
				if first_dec > 0 { line = first_dec }
			}
			append(&info.toplevel_def_lines, line)
		case ^parser.Class_Def:
			line := int(s.loc.line)
			if len(s.decorator_list) > 0 {
				first_dec := get_expr_line(s.decorator_list[0])
				if first_dec > 0 { line = first_dec }
			}
			append(&info.toplevel_def_lines, line)
			// Collect method defs inside class body
			for body_stmt in s.body {
				#partial switch ms in body_stmt {
				case ^parser.Func_Def:
					ml := int(ms.loc.line)
					if len(ms.decorator_list) > 0 {
						first_dec := get_expr_line(ms.decorator_list[0])
						if first_dec > 0 { ml = first_dec }
					}
					append(&info.method_def_lines, ml)
				case ^parser.Async_Func_Def:
					ml := int(ms.loc.line)
					if len(ms.decorator_list) > 0 {
						first_dec := get_expr_line(ms.decorator_list[0])
						if first_dec > 0 { ml = first_dec }
					}
					append(&info.method_def_lines, ml)
				}
			}
		}
	}

	// Collect string literals and trailing comma candidates from all statements
	collect_exprs_recursive(module.body, &info, allocator)

	return info
}

collect_exprs_recursive :: proc(stmts: []parser.Stmt, info: ^Struct_Info, allocator: mem.Allocator) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Expr_Stmt:
			collect_expr_info(s.value, info, allocator)
		case ^parser.Assign:
			collect_expr_info(s.value, info, allocator)
		case ^parser.Ann_Assign:
			if s.value != nil { collect_expr_info(s.value, info, allocator) }
		case ^parser.Aug_Assign:
			collect_expr_info(s.value, info, allocator)
		case ^parser.Return_Stmt:
			if s.value != nil { collect_expr_info(s.value, info, allocator) }
		case ^parser.Func_Def:
			collect_func_def_trailing_comma(s.loc, &s.args, info)
			collect_exprs_recursive(s.body, info, allocator)
		case ^parser.Async_Func_Def:
			collect_func_def_trailing_comma(s.loc, &s.args, info)
			collect_exprs_recursive(s.body, info, allocator)
		case ^parser.Class_Def:
			collect_exprs_recursive(s.body, info, allocator)
		case ^parser.If_Stmt:
			collect_expr_info(s.test, info, allocator)
			collect_exprs_recursive(s.body, info, allocator)
			collect_exprs_recursive(s.orelse, info, allocator)
		case ^parser.For_Stmt:
			collect_expr_info(s.iter, info, allocator)
			collect_exprs_recursive(s.body, info, allocator)
			collect_exprs_recursive(s.orelse, info, allocator)
		case ^parser.While_Stmt:
			collect_expr_info(s.test, info, allocator)
			collect_exprs_recursive(s.body, info, allocator)
		case ^parser.With_Stmt:
			collect_exprs_recursive(s.body, info, allocator)
		case ^parser.Try_Stmt:
			collect_exprs_recursive(s.body, info, allocator)
			for h in s.handlers { collect_exprs_recursive(h.body, info, allocator) }
			collect_exprs_recursive(s.orelse, info, allocator)
			collect_exprs_recursive(s.finalbody, info, allocator)
		case ^parser.Assert_Stmt:
			collect_expr_info(s.test, info, allocator)
		}
	}
}

collect_expr_info :: proc(expr: parser.Expr, info: ^Struct_Info, allocator: mem.Allocator) {
	if expr == nil { return }

	#partial switch e in expr {
	case ^parser.Constant_Expr:
		if _, ok := e.value.(string); ok {
			append(&info.string_locs, String_Loc{
				line    = int(e.loc.line),
				col     = int(e.loc.col),
				end_col = int(e.loc.end_col),
			})
		}
	case ^parser.Joined_Str:
		// f-string — mark as fstring to skip quote normalization
		append(&info.string_locs, String_Loc{
			line       = int(e.loc.line),
			col        = int(e.loc.col),
			end_col    = int(e.loc.end_col),
			is_fstring = true,
		})
	case ^parser.Call_Expr:
		// Check for multi-line call → trailing comma candidate
		if len(e.args) > 0 || len(e.keywords) > 0 {
			start_line := int(e.loc.line)
			end_line := int(e.loc.end_line)
			if end_line > start_line {
				// Multi-line call — find last arg/keyword
				last_end_line := 0
				last_end_col := 0
				for a in e.args {
					al, ac := get_expr_end(a)
					if al > last_end_line || (al == last_end_line && ac > last_end_col) {
						last_end_line = al
						last_end_col = ac
					}
				}
				for kw in e.keywords {
					kl, kc := get_expr_end(kw.value)
					if kl > last_end_line || (kl == last_end_line && kc > last_end_col) {
						last_end_line = kl
						last_end_col = kc
					}
				}
				if last_end_line > 0 && last_end_line < end_line {
					append(&info.trailing_comma_locs, Trailing_Comma_Loc{
						line    = last_end_line,
						end_col = last_end_col,
					})
				}
			}
		}
		collect_expr_info(e.func, info, allocator)
		for a in e.args { collect_expr_info(a, info, allocator) }
		for kw in e.keywords { collect_expr_info(kw.value, info, allocator) }
	case ^parser.List_Expr:
		if len(e.elts) > 0 {
			start_line := int(e.loc.line)
			end_line := int(e.loc.end_line)
			if end_line > start_line {
				last_el, last_ec := get_expr_end(e.elts[len(e.elts) - 1])
				if last_el > 0 && last_el < end_line {
					append(&info.trailing_comma_locs, Trailing_Comma_Loc{
						line    = last_el,
						end_col = last_ec,
					})
				}
			}
		}
		for elt in e.elts { collect_expr_info(elt, info, allocator) }
	case ^parser.Dict_Expr:
		if len(e.values) > 0 {
			start_line := int(e.loc.line)
			end_line := int(e.loc.end_line)
			if end_line > start_line {
				last_el, last_ec := get_expr_end(e.values[len(e.values) - 1])
				if last_el > 0 && last_el < end_line {
					append(&info.trailing_comma_locs, Trailing_Comma_Loc{
						line    = last_el,
						end_col = last_ec,
					})
				}
			}
		}
		for k in e.keys { collect_expr_info(k, info, allocator) }
		for v in e.values { collect_expr_info(v, info, allocator) }
	case ^parser.Set_Expr:
		if len(e.elts) > 0 {
			start_line := int(e.loc.line)
			end_line := int(e.loc.end_line)
			if end_line > start_line {
				last_el, last_ec := get_expr_end(e.elts[len(e.elts) - 1])
				if last_el > 0 && last_el < end_line {
					append(&info.trailing_comma_locs, Trailing_Comma_Loc{
						line    = last_el,
						end_col = last_ec,
					})
				}
			}
		}
		for elt in e.elts { collect_expr_info(elt, info, allocator) }
	case ^parser.Tuple_Expr:
		for elt in e.elts { collect_expr_info(elt, info, allocator) }
	case ^parser.Bin_Op_Expr:
		collect_expr_info(e.left, info, allocator)
		collect_expr_info(e.right, info, allocator)
	case ^parser.Unary_Op_Expr:
		collect_expr_info(e.operand, info, allocator)
	case ^parser.Compare_Expr:
		collect_expr_info(e.left, info, allocator)
		for c in e.comparators { collect_expr_info(c, info, allocator) }
	case ^parser.If_Expr:
		collect_expr_info(e.test, info, allocator)
		collect_expr_info(e.body, info, allocator)
		collect_expr_info(e.orelse, info, allocator)
	case ^parser.Attribute_Expr:
		collect_expr_info(e.value, info, allocator)
	case ^parser.Subscript_Expr:
		collect_expr_info(e.value, info, allocator)
	case ^parser.Bool_Op_Expr:
		for v in e.values { collect_expr_info(v, info, allocator) }
	}
}

collect_func_def_trailing_comma :: proc(loc: parser.Src_Loc, args: ^parser.Arguments, info: ^Struct_Info) {
	if args == nil { return }
	start_line := int(loc.line)

	// Find the last parameter's end location
	last_line := 0
	last_col := 0

	check_arg :: proc(a: parser.Arg, last_line: ^int, last_col: ^int) {
		el := int(a.loc.end_line)
		ec := int(a.loc.end_col)
		if el > last_line^ || (el == last_line^ && ec > last_col^) {
			last_line^ = el
			last_col^ = ec
		}
	}

	for &a in args.posonlyargs { check_arg(a, &last_line, &last_col) }
	for &a in args.args { check_arg(a, &last_line, &last_col) }
	for &a in args.kwonlyargs { check_arg(a, &last_line, &last_col) }
	if args.vararg != nil { check_arg(args.vararg^, &last_line, &last_col) }
	if args.kwarg != nil { check_arg(args.kwarg^, &last_line, &last_col) }

	// Only add trailing comma if multi-line (last param on different line than def)
	if last_line > start_line && last_line > 0 {
		append(&info.trailing_comma_locs, Trailing_Comma_Loc{
			line    = last_line,
			end_col = last_col,
		})
	}
}

// ==================== Pass 1: Line Normalization ====================

normalize_line :: proc(line: string, config: ^Format_Config, allocator: mem.Allocator) -> string {
	if len(line) == 0 { return line }

	// Strip trailing whitespace (but preserve the line itself)
	trimmed := strings.trim_right(line, " \t\r")

	// Normalize leading tabs to spaces
	if len(trimmed) > 0 && has_leading_tab(trimmed) {
		buf := make([dynamic]u8, 0, len(trimmed) + 16, allocator)
		i := 0
		for i < len(trimmed) {
			if trimmed[i] == '\t' {
				for _ in 0..<config.indent_width { append(&buf, ' ') }
				i += 1
			} else {
				break
			}
		}
		for j := i; j < len(trimmed); j += 1 {
			append(&buf, trimmed[j])
		}
		return string(buf[:])
	}

	return trimmed
}

has_leading_tab :: proc(s: string) -> bool {
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\t' { return true }
		if s[i] != ' ' { break }
	}
	return false
}

// ==================== Pass 2: Blank Line Normalization ====================

normalize_blank_lines :: proc(
	lines: []string,
	info: ^Struct_Info,
	prev_changed: bool,
	allocator: mem.Allocator,
) -> ([]string, bool) {
	result := make([dynamic]string, 0, len(lines) + 16, allocator)
	changed := prev_changed

	// First pass: copy lines into result, normalizing consecutive blanks
	consecutive_blanks := 0
	for i := 0; i < len(lines); i += 1 {
		is_blank := is_blank_line(lines[i])
		if is_blank {
			consecutive_blanks += 1
			if consecutive_blanks > 2 {
				changed = true
				continue // Skip excess blank lines
			}
		} else {
			consecutive_blanks = 0
		}
		append(&result, lines[i])
	}

	// Second pass: ensure correct blank lines before defs (content-based matching)
	final := make([dynamic]string, 0, len(result) + 16, allocator)
	has_content := false // tracks whether any non-blank content has been emitted

	for i := 0; i < len(result); i += 1 {
		line := result[i]
		trimmed := strings.trim_left_space(line)

		is_def_keyword := strings.has_prefix(trimmed, "def ") ||
		                  strings.has_prefix(trimmed, "class ") ||
		                  strings.has_prefix(trimmed, "async def ") ||
		                  strings.has_prefix(trimmed, "@")

		if is_def_keyword && has_content {
			is_toplevel := len(line) > 0 && line[0] != ' ' && line[0] != '\t'
			required_blanks := 2 if is_toplevel else 1
			blanks_before := count_trailing_blanks(final[:])
			for blanks_before < required_blanks {
				append(&final, "")
				blanks_before += 1
				changed = true
			}
		}

		if !is_blank_line(line) { has_content = true }
		append(&final, line)
	}

	// Remove trailing blank lines at end of file
	for len(final) > 0 && is_blank_line(final[len(final) - 1]) {
		pop(&final)
		changed = true
	}

	return final[:], changed
}

is_blank_line :: proc(line: string) -> bool {
	for c in line {
		if c != ' ' && c != '\t' && c != '\r' { return false }
	}
	return true
}

count_trailing_blanks :: proc(lines: []string) -> int {
	count := 0
	for i := len(lines) - 1; i >= 0; i -= 1 {
		if is_blank_line(lines[i]) {
			count += 1
		} else {
			break
		}
	}
	return count
}

// ==================== Pass 3: Quote Normalization ====================

normalize_quotes :: proc(
	line: string,
	loc: String_Loc,
	config: ^Format_Config,
	allocator: mem.Allocator,
) -> string {
	if loc.is_fstring { return line }  // Skip f-strings
	if loc.col < 0 || loc.col >= len(line) { return line }

	// Find the quote character at the AST-reported position
	col := loc.col
	// Skip prefixes: b, r, u, B, R, U
	for col < len(line) && (line[col] == 'b' || line[col] == 'B' ||
	                        line[col] == 'r' || line[col] == 'R' ||
	                        line[col] == 'u' || line[col] == 'U') {
		col += 1
	}
	if col >= len(line) { return line }

	current_quote := line[col]
	if current_quote != '\'' && current_quote != '"' { return line }

	// Check for triple quote
	if col + 2 < len(line) && line[col + 1] == current_quote && line[col + 2] == current_quote {
		return line // Skip triple-quoted strings
	}

	target_quote: u8 = '"' if config.quote_style == .Double else '\''
	if current_quote == target_quote { return line } // Already correct

	// Check if the string content contains the target quote
	// Find matching closing quote
	end := col + 1
	for end < len(line) {
		if line[end] == '\\' { end += 2; continue } // Skip escaped chars
		if line[end] == current_quote { break }
		if line[end] == target_quote { return line } // Content contains target quote, skip
		end += 1
	}
	if end >= len(line) { return line } // No closing quote found

	// Safe to swap quotes
	buf := make([dynamic]u8, 0, len(line), allocator)
	for i := 0; i < len(line); i += 1 {
		if i == col || i == end {
			append(&buf, target_quote)
		} else {
			append(&buf, line[i])
		}
	}
	return string(buf[:])
}

// ==================== Pass 4: Trailing Comma Insertion ====================

insert_trailing_comma :: proc(line: string, loc: Trailing_Comma_Loc, allocator: mem.Allocator) -> string {
	// Find the position after the last element on this line
	// Scan from end_col backwards to find non-whitespace, then check if comma exists
	trimmed := strings.trim_right(line, " \t")
	if len(trimmed) == 0 { return line }

	last_char := trimmed[len(trimmed) - 1]
	if last_char == ',' { return line }  // Already has trailing comma
	// Don't add after comment
	if last_char == '#' { return line }
	// Don't add after colon (dict entry handled by value, not key:)
	// Don't add after opening brackets
	if last_char == '(' || last_char == '[' || last_char == '{' { return line }
	if last_char == ':' { return line }

	// Check if this line has an inline comment — insert before comment
	comment_idx := find_unquoted_hash(trimmed)
	if comment_idx > 0 {
		before_comment := strings.trim_right(trimmed[:comment_idx], " \t")
		if len(before_comment) > 0 && before_comment[len(before_comment) - 1] != ',' {
			buf := make([dynamic]u8, 0, len(line) + 1, allocator)
			for c in before_comment { append(&buf, u8(c)) }
			append(&buf, ',')
			// Re-add spacing + comment
			for i := len(before_comment); i < len(trimmed); i += 1 {
				append(&buf, trimmed[i])
			}
			return string(buf[:])
		}
		return line
	}

	// Simple case: append comma
	buf := make([dynamic]u8, 0, len(trimmed) + 1, allocator)
	for c in trimmed { append(&buf, u8(c)) }
	append(&buf, ',')
	return string(buf[:])
}

find_unquoted_hash :: proc(s: string) -> int {
	in_single := false
	in_double := false
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '\\' { i += 2; continue }
		if c == '\'' && !in_double { in_single = !in_single }
		if c == '"' && !in_single { in_double = !in_double }
		if c == '#' && !in_single && !in_double { return i }
		i += 1
	}
	return -1
}

// ==================== Pass 4: Line Wrapping ====================

// C6: Main wrapping pass — iterates lines, wraps those exceeding line_length.
wrap_long_lines :: proc(lines: []string, config: ^Format_Config, allocator: mem.Allocator) -> ([]string, bool) {
	in_triple := mark_triple_string_regions(lines, allocator)
	result := make([dynamic]string, 0, len(lines) + 32, allocator)
	changed := false

	for i := 0; i < len(lines); i += 1 {
		line := lines[i]

		// Skip short lines, blank lines, and triple-string interiors
		if len(line) <= config.line_length || in_triple[i] {
			append(&result, line)
			continue
		}

		// Try import wrapping first
		import_prefix, import_names, is_import := detect_import_wrap(line, allocator)
		if is_import {
			wrapped := wrap_import(import_prefix, import_names, config, allocator)
			if len(wrapped) > 0 {
				for w in wrapped { append(&result, w) }
				changed = true
				continue
			}
		}

		// Try delimiter-based wrapping
		open_pos, close_pos, found_delim := find_wrappable_delimiter(line)
		if found_delim {
			elements := split_at_top_level_commas(line[open_pos + 1:close_pos], allocator)
			if len(elements) > 1 {
				wrapped := wrap_with_delimiter(line, open_pos, close_pos, elements, config, allocator)
				for w in wrapped { append(&result, w) }
				changed = true
				continue
			}
		}

		// Can't wrap — leave as-is
		append(&result, line)
	}

	return result[:], changed
}

// C1: Mark which lines are inside triple-quoted strings.
mark_triple_string_regions :: proc(lines: []string, allocator: mem.Allocator) -> []bool {
	in_triple := make([]bool, len(lines), allocator)
	inside := false
	quote_char: u8 = 0

	for i := 0; i < len(lines); i += 1 {
		line := lines[i]
		j := 0
		if inside {
			in_triple[i] = true
		}
		for j < len(line) {
			c := line[j]
			if !inside {
				// Skip single-char string prefixes
				if (c == 'r' || c == 'R' || c == 'b' || c == 'B' ||
				    c == 'u' || c == 'U' || c == 'f' || c == 'F') &&
				   j + 1 < len(line) && (line[j + 1] == '"' || line[j + 1] == '\'') {
					j += 1
					c = line[j]
				}
				if (c == '"' || c == '\'') && j + 2 < len(line) && line[j + 1] == c && line[j + 2] == c {
					inside = true
					quote_char = c
					in_triple[i] = true
					j += 3
					continue
				}
				// Skip single-quoted strings
				if c == '"' || c == '\'' {
					j += 1
					for j < len(line) {
						if line[j] == '\\' { j += 2; continue }
						if line[j] == c { j += 1; break }
						j += 1
					}
					continue
				}
				// Skip comments — rest of line is not code
				if c == '#' { break }
			} else {
				// Inside triple string — look for closing
				if c == quote_char && j + 2 < len(line) && line[j + 1] == quote_char && line[j + 2] == quote_char {
					inside = false
					j += 3
					continue
				}
				if c == '\\' { j += 2; continue }
			}
			j += 1
		}
	}

	return in_triple
}

// C2: Find outermost delimiter pair on a single line.
find_wrappable_delimiter :: proc(line: string) -> (open_pos: int, close_pos: int, ok: bool) {
	// Find first ( [ { that has a matching closer on same line
	depth_paren := 0
	depth_bracket := 0
	depth_brace := 0
	first_open := -1
	first_open_kind: u8 = 0
	in_single := false
	in_double := false

	for i := 0; i < len(line); i += 1 {
		c := line[i]
		if c == '\\' { i += 1; continue }
		if c == '\'' && !in_double { in_single = !in_single }
		if c == '"' && !in_single { in_double = !in_double }
		if in_single || in_double { continue }
		if c == '#' { break } // Comment — stop scanning

		switch c {
		case '(':
			if first_open < 0 { first_open = i; first_open_kind = '(' }
			depth_paren += 1
		case ')':
			depth_paren -= 1
			if depth_paren == 0 && first_open_kind == '(' {
				return first_open, i, true
			}
		case '[':
			if first_open < 0 { first_open = i; first_open_kind = '[' }
			depth_bracket += 1
		case ']':
			depth_bracket -= 1
			if depth_bracket == 0 && first_open_kind == '[' {
				return first_open, i, true
			}
		case '{':
			if first_open < 0 { first_open = i; first_open_kind = '{' }
			depth_brace += 1
		case '}':
			depth_brace -= 1
			if depth_brace == 0 && first_open_kind == '{' {
				return first_open, i, true
			}
		}
	}

	return -1, -1, false
}

// C3: Split text at top-level commas (depth 0, outside quotes).
// Handles lambda params (skip commas before ':') and comprehension detection.
split_at_top_level_commas :: proc(inner: string, allocator: mem.Allocator) -> []string {
	// Refuse to split comprehensions: content with ' for ' ... ' in ' pattern
	if is_comprehension_content(inner) {
		result := make([dynamic]string, 0, 1, allocator)
		append(&result, inner)
		return result[:]
	}

	elements := make([dynamic]string, 0, 8, allocator)
	depth := 0
	in_single := false
	in_double := false
	in_lambda := false  // inside lambda parameter list (before ':')
	start := 0

	for i := 0; i < len(inner); i += 1 {
		c := inner[i]
		if c == '\\' { i += 1; continue }
		if c == '\'' && !in_double { in_single = !in_single }
		if c == '"' && !in_single { in_double = !in_double }
		if in_single || in_double { continue }

		// Detect 'lambda ' keyword at depth 0
		if depth == 0 && !in_lambda && c == 'l' && i + 7 <= len(inner) && inner[i:i+7] == "lambda " {
			in_lambda = true
			i += 6 // skip past 'lambda' (loop will increment to space after)
			continue
		}

		// Lambda colon ends param list — commas after this are normal
		if in_lambda && depth == 0 && c == ':' {
			in_lambda = false
			continue
		}

		switch c {
		case '(', '[', '{': depth += 1
		case ')', ']', '}': depth -= 1
		case ',':
			if depth == 0 && !in_lambda {
				append(&elements, inner[start:i])
				start = i + 1
			}
		}
	}

	// Last element
	if start <= len(inner) {
		append(&elements, inner[start:])
	}

	return elements[:]
}

// Detect comprehension content: has ' for ' ... ' in ' at depth 0 outside quotes.
is_comprehension_content :: proc(inner: string) -> bool {
	depth := 0
	in_single := false
	in_double := false
	found_for := false

	for i := 0; i < len(inner); i += 1 {
		c := inner[i]
		if c == '\\' { i += 1; continue }
		if c == '\'' && !in_double { in_single = !in_single }
		if c == '"' && !in_single { in_double = !in_double }
		if in_single || in_double { continue }

		switch c {
		case '(', '[', '{': depth += 1
		case ')', ']', '}': depth -= 1
		}

		if depth == 0 && c == ' ' && i + 5 <= len(inner) && inner[i:i+5] == " for " {
			found_for = true
		}
		if found_for && depth == 0 && c == ' ' && i + 4 <= len(inner) && inner[i:i+4] == " in " {
			return true
		}
	}

	return false
}

// C4: Detect bare import pattern: from x import a, b, c (no parens).
detect_import_wrap :: proc(line: string, allocator: mem.Allocator) -> (prefix: string, names: string, ok: bool) {
	trimmed := strings.trim_left_space(line)

	// Match "from ... import ..." without parens
	if strings.has_prefix(trimmed, "from ") {
		import_idx := strings.index(trimmed, " import ")
		if import_idx < 0 { return "", "", false }
		after_import := trimmed[import_idx + 8:]
		// Already has parens — let delimiter-based wrapping handle it
		if len(after_import) > 0 && after_import[0] == '(' { return "", "", false }
		// Wildcard import — can't wrap
		if strings.trim_space(after_import) == "*" { return "", "", false }
		// Must have a comma to be wrappable
		if strings.index(after_import, ",") < 0 { return "", "", false }

		indent := line[:len(line) - len(trimmed)]
		prefix_str := fmt.aprintf("%s%s", indent, trimmed[:import_idx + 8], allocator = allocator)
		return prefix_str, after_import, true
	}

	return "", "", false
}

// C5a: Wrap a delimiter-based construct into multiple lines.
wrap_with_delimiter :: proc(
	line: string,
	open_pos: int,
	close_pos: int,
	elements: []string,
	config: ^Format_Config,
	allocator: mem.Allocator,
) -> []string {
	result := make([dynamic]string, 0, len(elements) + 2, allocator)
	indent := get_leading_whitespace(line)
	cont_indent := make_indent(indent, config.indent_width, allocator)

	// First line: everything up to and including open delimiter
	append(&result, line[:open_pos + 1])

	// Each element on its own line
	for elem in elements {
		trimmed := strings.trim_space(elem)
		if len(trimmed) == 0 { continue }
		append(&result, format_element_line(cont_indent, trimmed, allocator))
	}

	// Closing delimiter + suffix at base indent
	suffix := line[close_pos:]
	close_line := fmt.aprintf("%s%s", indent, suffix, allocator = allocator)
	append(&result, close_line)

	return result[:]
}

// C5b: Wrap a bare import into parenthesized multi-line form.
wrap_import :: proc(
	prefix: string,
	names: string,
	config: ^Format_Config,
	allocator: mem.Allocator,
) -> []string {
	elements := split_at_top_level_commas(names, allocator)
	if len(elements) <= 1 { return {} }

	result := make([dynamic]string, 0, len(elements) + 2, allocator)
	indent := get_leading_whitespace(prefix)
	cont_indent := make_indent(indent, config.indent_width, allocator)

	// First line: prefix + opening paren
	first_line := fmt.aprintf("%s(", prefix, allocator = allocator)
	append(&result, first_line)

	// Each name on its own line
	for elem in elements {
		trimmed := strings.trim_space(elem)
		if len(trimmed) == 0 { continue }
		append(&result, format_element_line(cont_indent, trimmed, allocator))
	}

	// Closing paren
	close_line := fmt.aprintf("%s)", indent, allocator = allocator)
	append(&result, close_line)

	return result[:]
}

// Format an element line with comma, handling inline comments.
// "elem  # comment" → "indent + elem,  # comment" (comma before comment).
format_element_line :: proc(indent: string, elem: string, allocator: mem.Allocator) -> string {
	hash_pos := find_unquoted_hash(elem)
	if hash_pos > 0 {
		before := strings.trim_right(elem[:hash_pos], " \t")
		comment := elem[hash_pos:]
		return fmt.aprintf("%s%s,  %s", indent, before, comment, allocator = allocator)
	}
	return fmt.aprintf("%s%s,", indent, elem, allocator = allocator)
}

// C6: Join multi-line constructs that exceed line length, then re-wrap.
// When trailing comma insertion or quote normalization pushes a line over the limit,
// and the closing delimiter is on a subsequent line, join them and re-wrap.
join_and_rewrap :: proc(lines: []string, config: ^Format_Config, allocator: mem.Allocator) -> ([]string, bool) {
	in_triple := mark_triple_string_regions(lines, allocator)
	result := make([dynamic]string, 0, len(lines) + 32, allocator)
	changed := false

	i := 0
	for i < len(lines) {
		line := lines[i]

		// Skip short lines, blank lines, and triple-string interiors
		if len(line) <= config.line_length || in_triple[i] {
			append(&result, line)
			i += 1
			continue
		}

		// Line is too long — check if it has an unmatched opening delimiter
		has_unmatched := has_unmatched_open(line)
		if has_unmatched {
			// Scan forward for continuation lines (closing delimiter)
			joined, end_idx := join_continuation(lines, i, allocator)
			if end_idx > i {
				// Re-wrap the joined line
				open_pos, close_pos, found_delim := find_wrappable_delimiter(joined)
				if found_delim {
					elements := split_at_top_level_commas(joined[open_pos + 1:close_pos], allocator)
					if len(elements) > 1 {
						wrapped := wrap_with_delimiter(joined, open_pos, close_pos, elements, config, allocator)
						for w in wrapped { append(&result, w) }
						changed = true
						i = end_idx + 1
						continue
					}
				}
				// Couldn't re-wrap — keep original lines
				for j in i..=end_idx {
					append(&result, lines[j])
				}
				i = end_idx + 1
				continue
			}
		}

		// Also try single-line re-wrap (line may have both delimiters)
		open_pos, close_pos, found_delim := find_wrappable_delimiter(line)
		if found_delim {
			elements := split_at_top_level_commas(line[open_pos + 1:close_pos], allocator)
			if len(elements) > 1 {
				wrapped := wrap_with_delimiter(line, open_pos, close_pos, elements, config, allocator)
				for w in wrapped { append(&result, w) }
				changed = true
				i += 1
				continue
			}
		}

		append(&result, line)
		i += 1
	}

	return result[:], changed
}

// Check if a line has more opening delimiters than closing ones (outside quotes).
has_unmatched_open :: proc(line: string) -> bool {
	depth := 0
	in_single := false
	in_double := false
	for i := 0; i < len(line); i += 1 {
		c := line[i]
		if c == '\\' { i += 1; continue }
		if c == '\'' && !in_double { in_single = !in_single }
		if c == '"' && !in_single { in_double = !in_double }
		if in_single || in_double { continue }
		if c == '#' { break }
		if c == '(' || c == '[' || c == '{' { depth += 1 }
		if c == ')' || c == ']' || c == '}' { depth -= 1 }
	}
	return depth > 0
}

// Join continuation lines from start_idx until delimiters balance.
join_continuation :: proc(lines: []string, start_idx: int, allocator: mem.Allocator) -> (joined: string, end_idx: int) {
	depth := 0
	in_single := false
	in_double := false

	for idx := start_idx; idx < len(lines) && idx < start_idx + 20; idx += 1 {
		line := lines[idx]
		for i := 0; i < len(line); i += 1 {
			c := line[i]
			if c == '\\' { i += 1; continue }
			if c == '\'' && !in_double { in_single = !in_single }
			if c == '"' && !in_single { in_double = !in_double }
			if in_single || in_double { continue }
			if c == '#' { break }
			if c == '(' || c == '[' || c == '{' { depth += 1 }
			if c == ')' || c == ']' || c == '}' { depth -= 1 }
		}

		if depth <= 0 && idx > start_idx {
			// Balanced — join all lines from start_idx to idx
			buf := strings.builder_make(allocator)
			for j := start_idx; j <= idx; j += 1 {
				trimmed := lines[j]
				if j > start_idx {
					trimmed = strings.trim_left_space(trimmed)
				}
				strings.write_string(&buf, trimmed)
			}
			return strings.to_string(buf), idx
		}
	}

	return "", start_idx
}

// Get leading whitespace from a line.
get_leading_whitespace :: proc(line: string) -> string {
	for i := 0; i < len(line); i += 1 {
		if line[i] != ' ' && line[i] != '\t' {
			return line[:i]
		}
	}
	return line
}

// Build continuation indent: base indent + N spaces.
make_indent :: proc(base: string, width: int, allocator: mem.Allocator) -> string {
	buf := make([dynamic]u8, 0, len(base) + width, allocator)
	for i := 0; i < len(base); i += 1 { append(&buf, base[i]) }
	for _ in 0..<width { append(&buf, ' ') }
	return string(buf[:])
}

// ==================== Diff Output ====================

print_diff :: proc(file: string, original: string, formatted: string) {
	orig_lines := strings.split(original, "\n")
	fmt_lines := strings.split(formatted, "\n")

	fmt.printfln("--- %s", file)
	fmt.printfln("+++ %s", file)

	// Simple line-by-line diff (not a real unified diff, but functional)
	max_lines := max(len(orig_lines), len(fmt_lines))
	chunk_start := -1
	for i := 0; i < max_lines; i += 1 {
		orig := orig_lines[i] if i < len(orig_lines) else ""
		fmtl := fmt_lines[i] if i < len(fmt_lines) else ""
		if orig != fmtl {
			if chunk_start < 0 { chunk_start = i }
		} else if chunk_start >= 0 {
			// Print chunk
			fmt.printfln("@@ -%d,%d +%d,%d @@", chunk_start + 1, i - chunk_start, chunk_start + 1, i - chunk_start)
			for j := chunk_start; j < i; j += 1 {
				if j < len(orig_lines) { fmt.printfln("-%s", orig_lines[j]) }
				if j < len(fmt_lines) { fmt.printfln("+%s", fmt_lines[j]) }
			}
			chunk_start = -1
		}
	}
	// Flush remaining chunk
	if chunk_start >= 0 {
		fmt.printfln("@@ -%d,%d +%d,%d @@", chunk_start + 1, max_lines - chunk_start, chunk_start + 1, max_lines - chunk_start)
		for j := chunk_start; j < max_lines; j += 1 {
			if j < len(orig_lines) { fmt.printfln("-%s", orig_lines[j]) }
			if j < len(fmt_lines) { fmt.printfln("+%s", fmt_lines[j]) }
		}
	}
}

// ==================== Helpers ====================

split_lines :: proc(source: string, allocator: mem.Allocator) -> []string {
	lines := make([dynamic]string, 0, 64, allocator)
	start := 0
	for i := 0; i < len(source); i += 1 {
		if source[i] == '\n' {
			// Line content without the newline
			line_end := i
			if line_end > start && source[line_end - 1] == '\r' {
				line_end -= 1
			}
			append(&lines, source[start:line_end])
			start = i + 1
		}
	}
	// Last line (may not end with newline)
	if start < len(source) {
		line_end := len(source)
		if line_end > start && source[line_end - 1] == '\r' {
			line_end -= 1
		}
		append(&lines, source[start:line_end])
	}
	return lines[:]
}

join_lines :: proc(lines: []string, allocator: mem.Allocator) -> string {
	total := 0
	for line in lines { total += len(line) + 1 } // +1 for newline
	buf := make([dynamic]u8, 0, total, allocator)
	for line in lines {
		for c in line { append(&buf, u8(c)) }
		append(&buf, '\n')
	}
	return string(buf[:])
}

get_expr_line :: proc(expr: parser.Expr) -> int {
	#partial switch e in expr {
	case ^parser.Name_Expr:      return int(e.loc.line)
	case ^parser.Call_Expr:      return int(e.loc.line)
	case ^parser.Attribute_Expr: return int(e.loc.line)
	case ^parser.Constant_Expr:  return int(e.loc.line)
	}
	return 0
}

get_expr_end :: proc(expr: parser.Expr) -> (int, int) {
	#partial switch e in expr {
	case ^parser.Name_Expr:      return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Call_Expr:      return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Attribute_Expr: return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Constant_Expr:  return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.List_Expr:      return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Dict_Expr:      return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Set_Expr:       return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Tuple_Expr:     return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Bin_Op_Expr:    return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Unary_Op_Expr:  return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Bool_Op_Expr:   return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Compare_Expr:   return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.If_Expr:        return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Lambda_Expr:    return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Subscript_Expr: return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Starred_Expr:    return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Joined_Str:      return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Await_Expr:      return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Named_Expr:      return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Formatted_Value: return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Generator_Expr:  return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.List_Comp:       return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Set_Comp:        return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Dict_Comp:       return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Yield_Expr:      return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Yield_From_Expr: return int(e.loc.end_line), int(e.loc.end_col)
	case ^parser.Slice_Expr:      return int(e.loc.end_line), int(e.loc.end_col)
	}
	return 0, 0
}
