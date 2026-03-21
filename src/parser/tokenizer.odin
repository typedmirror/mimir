package parser

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:strconv"
import "core:unicode/utf8"

// ==================== Token Types ====================

Token_Kind :: enum u8 {
	// Literals
	INT, FLOAT, COMPLEX, STRING, BYTES, FSTRING,
	// Identifiers
	NAME,
	// Keywords (35)
	KW_FALSE, KW_NONE, KW_TRUE,
	KW_AND, KW_AS, KW_ASSERT, KW_ASYNC, KW_AWAIT,
	KW_BREAK, KW_CLASS, KW_CONTINUE, KW_DEF, KW_DEL,
	KW_ELIF, KW_ELSE, KW_EXCEPT, KW_FINALLY, KW_FOR,
	KW_FROM, KW_GLOBAL, KW_IF, KW_IMPORT, KW_IN,
	KW_IS, KW_LAMBDA, KW_NONLOCAL, KW_NOT, KW_OR,
	KW_PASS, KW_RAISE, KW_RETURN, KW_TRY, KW_WHILE,
	KW_WITH, KW_YIELD,
	// Soft keywords (context-sensitive)
	KW_MATCH, KW_CASE, KW_TYPE,
	// Operators
	PLUS, MINUS, STAR, DOUBLE_STAR, SLASH, DOUBLE_SLASH,
	PERCENT, AT, AMPERSAND, PIPE, CARET, TILDE,
	LSHIFT, RSHIFT,
	// Comparison
	LT, GT, LE, GE, EQ_EQ, NOT_EQ,
	// Assignment
	ASSIGN, WALRUS,
	PLUS_EQ, MINUS_EQ, STAR_EQ, SLASH_EQ, DOUBLE_SLASH_EQ,
	PERCENT_EQ, AT_EQ, AMPERSAND_EQ, PIPE_EQ, CARET_EQ,
	LSHIFT_EQ, RSHIFT_EQ, DOUBLE_STAR_EQ,
	// Delimiters
	LPAREN, RPAREN, LBRACKET, RBRACKET, LBRACE, RBRACE,
	COMMA, COLON, SEMICOLON, DOT, ELLIPSIS, ARROW,
	// Structure
	NEWLINE, INDENT, DEDENT, EOF, ERROR,
}

Token :: struct {
	kind: Token_Kind,
	text: string,
	loc:  Src_Loc,
}

// ==================== Tokenizer State ====================

Tokenizer :: struct {
	source:       string,
	pos:          int,
	line:         i32,
	col:          i32,
	// Indentation
	indent_stack: [dynamic]int,   // stack of indent levels
	pending:      [dynamic]Token, // pending INDENT/DEDENT/NEWLINE tokens
	at_line_start: bool,
	// Bracket nesting (implicit line continuation)
	bracket_depth: int,
	// Output
	tokens:       [dynamic]Token,
	allocator:    mem.Allocator,
}

// ==================== Keyword Lookup ====================

keyword_lookup :: proc(name: string) -> (Token_Kind, bool) {
	switch name {
	case "False":    return .KW_FALSE, true
	case "None":     return .KW_NONE, true
	case "True":     return .KW_TRUE, true
	case "and":      return .KW_AND, true
	case "as":       return .KW_AS, true
	case "assert":   return .KW_ASSERT, true
	case "async":    return .KW_ASYNC, true
	case "await":    return .KW_AWAIT, true
	case "break":    return .KW_BREAK, true
	case "class":    return .KW_CLASS, true
	case "continue": return .KW_CONTINUE, true
	case "def":      return .KW_DEF, true
	case "del":      return .KW_DEL, true
	case "elif":     return .KW_ELIF, true
	case "else":     return .KW_ELSE, true
	case "except":   return .KW_EXCEPT, true
	case "finally":  return .KW_FINALLY, true
	case "for":      return .KW_FOR, true
	case "from":     return .KW_FROM, true
	case "global":   return .KW_GLOBAL, true
	case "if":       return .KW_IF, true
	case "import":   return .KW_IMPORT, true
	case "in":       return .KW_IN, true
	case "is":       return .KW_IS, true
	case "lambda":   return .KW_LAMBDA, true
	case "nonlocal": return .KW_NONLOCAL, true
	case "not":      return .KW_NOT, true
	case "or":       return .KW_OR, true
	case "pass":     return .KW_PASS, true
	case "raise":    return .KW_RAISE, true
	case "return":   return .KW_RETURN, true
	case "try":      return .KW_TRY, true
	case "while":    return .KW_WHILE, true
	case "with":     return .KW_WITH, true
	case "yield":    return .KW_YIELD, true
	// Soft keywords — returned as NAME, caller disambiguates
	case "match":    return .KW_MATCH, true
	case "case":     return .KW_CASE, true
	case "type":     return .KW_TYPE, true
	}
	return .NAME, false
}

// ==================== Entry Point ====================

tokenize :: proc(source: string, allocator: mem.Allocator) -> ([]Token, Parse_Error) {
	t: Tokenizer
	t.source = source
	t.pos = 0
	t.line = 1
	t.col = 0
	t.at_line_start = true
	t.bracket_depth = 0
	t.indent_stack = make([dynamic]int, 0, 16, allocator)
	t.pending = make([dynamic]Token, 0, 8, allocator)
	t.tokens = make([dynamic]Token, 0, len(source) / 4, allocator)
	t.allocator = allocator

	// Initial indent level
	append(&t.indent_stack, 0)

	for t.pos < len(t.source) {
		err := _next_token(&t)
		if err != nil { return nil, err }
	}

	// Emit final NEWLINE if needed
	if len(t.tokens) > 0 && t.tokens[len(t.tokens) - 1].kind != .NEWLINE {
		_emit(&t, .NEWLINE, "", t.line, t.col)
	}

	// Emit DEDENT tokens for remaining indent levels
	for len(t.indent_stack) > 1 {
		pop(&t.indent_stack)
		_emit(&t, .DEDENT, "", t.line, t.col)
	}

	_emit(&t, .EOF, "", t.line, t.col)
	return t.tokens[:], nil
}

// ==================== Core Tokenizer ====================

_next_token :: proc(t: ^Tokenizer) -> Parse_Error {
	// Drain pending tokens first
	for len(t.pending) > 0 {
		tok := pop_front(&t.pending)
		append(&t.tokens, tok)
	}

	if t.pos >= len(t.source) { return nil }

	// Handle line start: indentation
	if t.at_line_start {
		t.at_line_start = false
		if t.bracket_depth == 0 {
			return _handle_indentation(t)
		}
	}

	c := t.source[t.pos]

	// Skip spaces and tabs (not at line start — already handled)
	if c == ' ' || c == '\t' {
		t.pos += 1
		t.col += 1
		return nil
	}

	// Comments
	if c == '#' {
		_skip_comment(t)
		return nil
	}

	// Newlines
	if c == '\n' || c == '\r' {
		return _handle_newline(t)
	}

	// Continuation line
	if c == '\\' && t.pos + 1 < len(t.source) {
		next := t.source[t.pos + 1]
		if next == '\n' {
			t.pos += 2
			t.line += 1
			t.col = 0
			return nil
		}
		if next == '\r' {
			t.pos += 2
			if t.pos < len(t.source) && t.source[t.pos] == '\n' {
				t.pos += 1
			}
			t.line += 1
			t.col = 0
			return nil
		}
	}

	// Strings
	if c == '\'' || c == '"' {
		return _scan_string(t, false, false)
	}
	// String prefixes: r, b, f, u, rb, br, rf, fr
	if _is_string_prefix(t) {
		return _scan_prefixed_string(t)
	}

	// Numbers
	if c >= '0' && c <= '9' {
		return _scan_number(t)
	}
	// .123 float
	if c == '.' && t.pos + 1 < len(t.source) && t.source[t.pos + 1] >= '0' && t.source[t.pos + 1] <= '9' {
		return _scan_number(t)
	}

	// Identifiers and keywords
	if _is_id_start(c) {
		return _scan_identifier(t)
	}

	// Operators and delimiters
	return _scan_operator(t)
}

// ==================== Indentation ====================

_handle_indentation :: proc(t: ^Tokenizer) -> Parse_Error {
	indent := 0
	start := t.pos
	for t.pos < len(t.source) {
		c := t.source[t.pos]
		if c == ' ' {
			indent += 1
			t.pos += 1
		} else if c == '\t' {
			indent += 8 - (indent % 8) // tab stops at multiples of 8
			t.pos += 1
		} else {
			break
		}
	}
	t.col = i32(indent)

	// Blank line or comment-only line — skip entirely
	if t.pos >= len(t.source) || t.source[t.pos] == '\n' || t.source[t.pos] == '\r' || t.source[t.pos] == '#' {
		return nil
	}

	current_indent := t.indent_stack[len(t.indent_stack) - 1]

	if indent > current_indent {
		append(&t.indent_stack, indent)
		_emit(t, .INDENT, "", t.line, 0)
	} else if indent < current_indent {
		// Pop indent levels and emit DEDENT for each
		for len(t.indent_stack) > 1 && t.indent_stack[len(t.indent_stack) - 1] > indent {
			pop(&t.indent_stack)
			_emit(t, .DEDENT, "", t.line, 0)
		}
		if t.indent_stack[len(t.indent_stack) - 1] != indent {
			return Syntax_Error{
				msg  = "unindent does not match any outer indentation level",
				file = "",
				line = int(t.line),
				col  = int(t.col),
			}
		}
	}
	return nil
}

// ==================== Newlines ====================

_handle_newline :: proc(t: ^Tokenizer) -> Parse_Error {
	// Consume \n or \r\n
	if t.source[t.pos] == '\r' {
		t.pos += 1
		if t.pos < len(t.source) && t.source[t.pos] == '\n' {
			t.pos += 1
		}
	} else {
		t.pos += 1
	}

	t.line += 1
	t.col = 0
	t.at_line_start = true

	// Only emit NEWLINE if not inside brackets
	if t.bracket_depth == 0 {
		// Don't emit consecutive NEWLINEs
		if len(t.tokens) > 0 && t.tokens[len(t.tokens) - 1].kind != .NEWLINE {
			_emit(t, .NEWLINE, "", t.line - 1, t.col)
		}
	}
	return nil
}

// ==================== Identifiers ====================

_scan_identifier :: proc(t: ^Tokenizer) -> Parse_Error {
	start := t.pos
	start_col := t.col
	t.pos += 1
	t.col += 1
	for t.pos < len(t.source) && _is_id_continue(t.source[t.pos]) {
		t.pos += 1
		t.col += 1
	}
	text := t.source[start:t.pos]

	kind, is_kw := keyword_lookup(text)
	if !is_kw { kind = .NAME }

	_emit(t, kind, text, t.line, start_col)
	return nil
}

_is_id_start :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c > 127
}

_is_id_continue :: proc(c: u8) -> bool {
	return _is_id_start(c) || (c >= '0' && c <= '9')
}

// ==================== Numbers ====================

_scan_number :: proc(t: ^Tokenizer) -> Parse_Error {
	start := t.pos
	start_col := t.col
	kind := Token_Kind.INT

	c := t.source[t.pos]

	// 0x, 0o, 0b, 0X, 0O, 0B prefixes
	if c == '0' && t.pos + 1 < len(t.source) {
		next := t.source[t.pos + 1]
		if next == 'x' || next == 'X' {
			t.pos += 2; t.col += 2
			_scan_hex_digits(t)
			if t.pos < len(t.source) && (t.source[t.pos] == 'j' || t.source[t.pos] == 'J') {
				kind = .COMPLEX; t.pos += 1; t.col += 1
			}
			_emit(t, kind, t.source[start:t.pos], t.line, start_col)
			return nil
		}
		if next == 'o' || next == 'O' {
			t.pos += 2; t.col += 2
			_scan_oct_digits(t)
			_emit(t, kind, t.source[start:t.pos], t.line, start_col)
			return nil
		}
		if next == 'b' || next == 'B' {
			t.pos += 2; t.col += 2
			_scan_bin_digits(t)
			_emit(t, kind, t.source[start:t.pos], t.line, start_col)
			return nil
		}
	}

	// Decimal integer or float
	if c == '.' {
		// .123 form
		kind = .FLOAT
	} else {
		_scan_dec_digits(t)
	}

	// Check for decimal point
	if t.pos < len(t.source) && t.source[t.pos] == '.' {
		// Make sure it's not .. (ellipsis start)
		if t.pos + 1 < len(t.source) && t.source[t.pos + 1] == '.' {
			// Integer followed by .. — don't consume
		} else {
			kind = .FLOAT
			t.pos += 1; t.col += 1
			_scan_dec_digits(t)
		}
	}

	// Exponent
	if t.pos < len(t.source) && (t.source[t.pos] == 'e' || t.source[t.pos] == 'E') {
		kind = .FLOAT
		t.pos += 1; t.col += 1
		if t.pos < len(t.source) && (t.source[t.pos] == '+' || t.source[t.pos] == '-') {
			t.pos += 1; t.col += 1
		}
		_scan_dec_digits(t)
	}

	// Complex suffix
	if t.pos < len(t.source) && (t.source[t.pos] == 'j' || t.source[t.pos] == 'J') {
		kind = .COMPLEX
		t.pos += 1; t.col += 1
	}

	_emit(t, kind, t.source[start:t.pos], t.line, start_col)
	return nil
}

_scan_dec_digits :: proc(t: ^Tokenizer) {
	for t.pos < len(t.source) {
		c := t.source[t.pos]
		if (c >= '0' && c <= '9') || c == '_' {
			t.pos += 1; t.col += 1
		} else {
			break
		}
	}
}

_scan_hex_digits :: proc(t: ^Tokenizer) {
	for t.pos < len(t.source) {
		c := t.source[t.pos]
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') || c == '_' {
			t.pos += 1; t.col += 1
		} else {
			break
		}
	}
}

_scan_oct_digits :: proc(t: ^Tokenizer) {
	for t.pos < len(t.source) {
		c := t.source[t.pos]
		if (c >= '0' && c <= '7') || c == '_' {
			t.pos += 1; t.col += 1
		} else {
			break
		}
	}
}

_scan_bin_digits :: proc(t: ^Tokenizer) {
	for t.pos < len(t.source) {
		c := t.source[t.pos]
		if c == '0' || c == '1' || c == '_' {
			t.pos += 1; t.col += 1
		} else {
			break
		}
	}
}

// ==================== Strings ====================

_is_string_prefix :: proc(t: ^Tokenizer) -> bool {
	if t.pos >= len(t.source) { return false }
	c := t.source[t.pos]
	if c != 'r' && c != 'R' && c != 'b' && c != 'B' && c != 'f' && c != 'F' && c != 'u' && c != 'U' {
		return false
	}
	// Look ahead for quote
	ahead := t.pos + 1
	if ahead < len(t.source) {
		if t.source[ahead] == '\'' || t.source[ahead] == '"' { return true }
		// Two-char prefix: rb, br, rf, fr
		nc := t.source[ahead]
		if (nc == 'b' || nc == 'B' || nc == 'r' || nc == 'R' || nc == 'f' || nc == 'F') && ahead + 1 < len(t.source) {
			if t.source[ahead + 1] == '\'' || t.source[ahead + 1] == '"' { return true }
		}
	}
	return false
}

_scan_prefixed_string :: proc(t: ^Tokenizer) -> Parse_Error {
	is_raw := false
	is_bytes := false
	is_fstring := false

	// Consume prefix chars
	for t.pos < len(t.source) {
		c := t.source[t.pos]
		switch c {
		case 'r', 'R': is_raw = true;    t.pos += 1; t.col += 1
		case 'b', 'B': is_bytes = true;  t.pos += 1; t.col += 1
		case 'f', 'F': is_fstring = true; t.pos += 1; t.col += 1
		case 'u', 'U': t.pos += 1; t.col += 1
		case: break
		}
		if t.pos < len(t.source) && (t.source[t.pos] == '\'' || t.source[t.pos] == '"') {
			break
		}
	}

	return _scan_string(t, is_raw, is_bytes || is_fstring)
}

_scan_string :: proc(t: ^Tokenizer, is_raw: bool, is_special: bool) -> Parse_Error {
	start := t.pos
	// Account for prefix chars already consumed
	start_for_text := start
	// Find actual quote start — scan back from prefix handling
	for i := start - 1; i >= 0; i -= 1 {
		c := t.source[i]
		if c == 'r' || c == 'R' || c == 'b' || c == 'B' || c == 'f' || c == 'F' || c == 'u' || c == 'U' {
			start_for_text = i
		} else {
			break
		}
	}
	if start_for_text > start { start_for_text = start }

	start_col := t.col
	quote := t.source[t.pos]
	triple := false

	// Check for triple quote
	if t.pos + 2 < len(t.source) && t.source[t.pos + 1] == quote && t.source[t.pos + 2] == quote {
		triple = true
		t.pos += 3; t.col += 3
	} else {
		t.pos += 1; t.col += 1
	}

	// Scan string body
	for t.pos < len(t.source) {
		c := t.source[t.pos]

		if c == '\\' && !is_raw {
			// Escape sequence — skip next char
			t.pos += 1; t.col += 1
			if t.pos < len(t.source) {
				if t.source[t.pos] == '\n' {
					t.line += 1; t.col = 0
				} else {
					t.col += 1
				}
				t.pos += 1
			}
			continue
		}

		if c == '\n' {
			if !triple {
				return Syntax_Error{
					msg  = "EOL while scanning string literal",
					file = "",
					line = int(t.line),
					col  = int(start_col),
				}
			}
			t.line += 1; t.col = 0
			t.pos += 1
			continue
		}

		if c == quote {
			if triple {
				if t.pos + 2 < len(t.source) && t.source[t.pos + 1] == quote && t.source[t.pos + 2] == quote {
					t.pos += 3; t.col += 3
					break
				}
				t.pos += 1; t.col += 1
				continue
			}
			t.pos += 1; t.col += 1
			break
		}

		t.pos += 1; t.col += 1
	}

	text := t.source[start_for_text:t.pos]

	// Determine token kind
	kind := Token_Kind.STRING
	// Check prefix for bytes/fstring
	for i := start_for_text; i < start; i += 1 {
		c := t.source[i]
		if c == 'b' || c == 'B' { kind = .BYTES; break }
		if c == 'f' || c == 'F' { kind = .FSTRING; break }
	}

	_emit(t, kind, text, t.line, start_col)
	return nil
}

// ==================== Operators ====================

_scan_operator :: proc(t: ^Tokenizer) -> Parse_Error {
	start_col := t.col
	c := t.source[t.pos]
	next: u8 = 0
	if t.pos + 1 < len(t.source) { next = t.source[t.pos + 1] }
	next2: u8 = 0
	if t.pos + 2 < len(t.source) { next2 = t.source[t.pos + 2] }

	kind: Token_Kind
	advance := 1

	switch c {
	case '(':
		kind = .LPAREN; t.bracket_depth += 1
	case ')':
		kind = .RPAREN; t.bracket_depth -= 1
	case '[':
		kind = .LBRACKET; t.bracket_depth += 1
	case ']':
		kind = .RBRACKET; t.bracket_depth -= 1
	case '{':
		kind = .LBRACE; t.bracket_depth += 1
	case '}':
		kind = .RBRACE; t.bracket_depth -= 1
	case ',':
		kind = .COMMA
	case ';':
		kind = .SEMICOLON
	case '~':
		kind = .TILDE
	case '.':
		if next == '.' && next2 == '.' {
			kind = .ELLIPSIS; advance = 3
		} else {
			kind = .DOT
		}
	case ':':
		if next == '=' { kind = .WALRUS; advance = 2 }
		else { kind = .COLON }
	case '+':
		if next == '=' { kind = .PLUS_EQ; advance = 2 }
		else { kind = .PLUS }
	case '-':
		if next == '>' { kind = .ARROW; advance = 2 }
		else if next == '=' { kind = .MINUS_EQ; advance = 2 }
		else { kind = .MINUS }
	case '*':
		if next == '*' {
			if next2 == '=' { kind = .DOUBLE_STAR_EQ; advance = 3 }
			else { kind = .DOUBLE_STAR; advance = 2 }
		} else if next == '=' { kind = .STAR_EQ; advance = 2 }
		else { kind = .STAR }
	case '/':
		if next == '/' {
			if next2 == '=' { kind = .DOUBLE_SLASH_EQ; advance = 3 }
			else { kind = .DOUBLE_SLASH; advance = 2 }
		} else if next == '=' { kind = .SLASH_EQ; advance = 2 }
		else { kind = .SLASH }
	case '%':
		if next == '=' { kind = .PERCENT_EQ; advance = 2 }
		else { kind = .PERCENT }
	case '@':
		if next == '=' { kind = .AT_EQ; advance = 2 }
		else { kind = .AT }
	case '&':
		if next == '=' { kind = .AMPERSAND_EQ; advance = 2 }
		else { kind = .AMPERSAND }
	case '|':
		if next == '=' { kind = .PIPE_EQ; advance = 2 }
		else { kind = .PIPE }
	case '^':
		if next == '=' { kind = .CARET_EQ; advance = 2 }
		else { kind = .CARET }
	case '<':
		if next == '<' {
			if next2 == '=' { kind = .LSHIFT_EQ; advance = 3 }
			else { kind = .LSHIFT; advance = 2 }
		} else if next == '=' { kind = .LE; advance = 2 }
		else { kind = .LT }
	case '>':
		if next == '>' {
			if next2 == '=' { kind = .RSHIFT_EQ; advance = 3 }
			else { kind = .RSHIFT; advance = 2 }
		} else if next == '=' { kind = .GE; advance = 2 }
		else { kind = .GT }
	case '=':
		if next == '=' { kind = .EQ_EQ; advance = 2 }
		else { kind = .ASSIGN }
	case '!':
		if next == '=' { kind = .NOT_EQ; advance = 2 }
		else {
			kind = .ERROR
			t.pos += 1; t.col += 1
			return Syntax_Error{
				msg  = fmt.tprintf("unexpected character '!'"),
				file = "",
				line = int(t.line),
				col  = int(start_col),
			}
		}
	case:
		kind = .ERROR
		t.pos += 1; t.col += 1
		return Syntax_Error{
			msg  = fmt.tprintf("unexpected character '%c'", rune(c)),
			file = "",
			line = int(t.line),
			col  = int(start_col),
		}
	}

	text := t.source[t.pos:t.pos + advance]
	t.pos += advance
	t.col += i32(advance)
	_emit(t, kind, text, t.line, start_col)
	return nil
}

// ==================== Helpers ====================

_emit :: proc(t: ^Tokenizer, kind: Token_Kind, text: string, line: i32, col: i32) {
	append(&t.tokens, Token{
		kind = kind,
		text = text,
		loc  = Src_Loc{line = line, col = col},
	})
}

_skip_comment :: proc(t: ^Tokenizer) {
	for t.pos < len(t.source) && t.source[t.pos] != '\n' && t.source[t.pos] != '\r' {
		t.pos += 1
		t.col += 1
	}
}

// pop_front for [dynamic] — O(n) but pending queue is tiny
pop_front :: proc(arr: ^[dynamic]Token) -> Token {
	if len(arr^) == 0 { return {} }
	val := arr[0]
	ordered_remove(arr, 0)
	return val
}
