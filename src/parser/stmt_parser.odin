package parser

import "core:fmt"
import "core:mem"
import "core:strings"

// ==================== Module Parser ====================

parse_module_native :: proc(ctx: ^Parser_Context) -> ^Module {
	_skip_newlines(ctx)

	body := make([dynamic]Stmt, 0, 32, ctx.allocator)
	for !_at(ctx, .EOF) {
		_skip_newlines(ctx)
		if _at(ctx, .EOF) { break }
		stmt := _parse_stmt(ctx)
		if stmt != nil { append(&body, stmt) }
		_skip_newlines(ctx)
	}

	mod := new(Module, ctx.allocator)
	mod.body = body[:]
	return mod
}

// ==================== Statement Parser ====================

_parse_stmt :: proc(ctx: ^Parser_Context) -> Stmt {
	tok := _peek(ctx)

	#partial switch tok.kind {
	case .KW_DEF:      return _parse_func_def(ctx, false)
	case .KW_ASYNC:    return _parse_async(ctx)
	case .KW_CLASS:    return _parse_class_def(ctx)
	case .KW_RETURN:   return _parse_return(ctx)
	case .KW_DEL:      return _parse_del(ctx)
	case .KW_IF:       return _parse_if(ctx)
	case .KW_WHILE:    return _parse_while(ctx)
	case .KW_FOR:      return _parse_for(ctx, false)
	case .KW_WITH:     return _parse_with(ctx, false)
	case .KW_RAISE:    return _parse_raise(ctx)
	case .KW_TRY:      return _parse_try(ctx)
	case .KW_ASSERT:   return _parse_assert(ctx)
	case .KW_IMPORT:   return _parse_import(ctx)
	case .KW_FROM:     return _parse_from_import(ctx)
	case .KW_GLOBAL:   return _parse_global(ctx)
	case .KW_NONLOCAL: return _parse_nonlocal(ctx)
	case .KW_PASS:     _advance(ctx); _consume_newline(ctx); n := new(Pass_Stmt, ctx.allocator); n.loc = tok.loc; return n
	case .KW_BREAK:    _advance(ctx); _consume_newline(ctx); n := new(Break_Stmt, ctx.allocator); n.loc = tok.loc; return n
	case .KW_CONTINUE: _advance(ctx); _consume_newline(ctx); n := new(Continue_Stmt, ctx.allocator); n.loc = tok.loc; return n
	case .KW_MATCH:    return _parse_match_or_expr(ctx)
	case .KW_TYPE:     return _parse_type_alias_or_expr(ctx)
	case .AT:          return _parse_decorated(ctx)
	case .INDENT:      return _parse_unexpected_indent(ctx)
	case .DEDENT:      _advance(ctx); return nil
	}

	// Expression statement or assignment
	return _parse_expr_or_assign(ctx)
}

// ==================== Block Parsing ====================

_parse_block :: proc(ctx: ^Parser_Context) -> []Stmt {
	// Expect NEWLINE + INDENT for multi-line blocks
	if _at(ctx, .NEWLINE) {
		_advance(ctx)
		_skip_newlines(ctx)
	}

	if _at(ctx, .INDENT) {
		_advance(ctx)
		stmts := make([dynamic]Stmt, 0, 8, ctx.allocator)
		for !_at(ctx, .DEDENT) && !_at(ctx, .EOF) {
			_skip_newlines(ctx)
			if _at(ctx, .DEDENT) || _at(ctx, .EOF) { break }
			s := _parse_stmt(ctx)
			if s != nil { append(&stmts, s) }
			_skip_newlines(ctx)
		}
		if _at(ctx, .DEDENT) { _advance(ctx) }
		return stmts[:]
	}

	// Single-line block (e.g., `if x: return y`)
	stmts := make([dynamic]Stmt, 0, 1, ctx.allocator)
	// Parse statements until newline
	for !_at_any(ctx, .NEWLINE, .EOF, .DEDENT) {
		s := _parse_stmt(ctx)
		if s != nil { append(&stmts, s) }
		if _at(ctx, .SEMICOLON) { _advance(ctx) } else { break }
	}
	_consume_newline(ctx)
	return stmts[:]
}

// Parse target list for for/del/assign — stops at 'in' keyword.
_parse_target_list :: proc(ctx: ^Parser_Context) -> Expr {
	// Parse a single target expression without consuming 'in'
	first := _parse_target_expr(ctx)
	if first == nil { return nil }

	if !_at(ctx, .COMMA) { return first }

	elts := make([dynamic]Expr, 0, 4, ctx.allocator)
	append(&elts, first)
	for _at(ctx, .COMMA) {
		_advance(ctx)
		if _at_any(ctx, .KW_IN, .COLON, .NEWLINE, .EOF) { break }
		e := _parse_target_expr(ctx)
		if e != nil { append(&elts, e) }
	}

	t := new(Tuple_Expr, ctx.allocator)
	t.loc = _expr_loc(first)
	t.elts = elts[:]
	t.ctx = .Store
	return t
}

// Parse a single target — name, attribute, subscript, tuple unpack. Stops at 'in'.
_parse_target_expr :: proc(ctx: ^Parser_Context) -> Expr {
	if _at(ctx, .STAR) {
		tok := _advance(ctx)
		inner := _parse_target_expr(ctx)
		s := new(Starred_Expr, ctx.allocator)
		s.loc = tok.loc
		s.value = inner
		s.ctx = .Store
		return s
	}

	if _at(ctx, .LPAREN) {
		_advance(ctx)
		inner := _parse_target_list(ctx)
		_expect(ctx, .RPAREN)
		return inner
	}

	if _at(ctx, .LBRACKET) {
		_advance(ctx)
		inner := _parse_target_list(ctx)
		_expect(ctx, .RBRACKET)
		return inner
	}

	// Simple name or dotted/subscript
	left := parse_expr(ctx, PREC_POSTFIX)

	// Allow postfix .attr and [sub] on targets
	for _at_any(ctx, .DOT, .LBRACKET) {
		if _at(ctx, .DOT) { left = _parse_attribute(ctx, left) }
		else if _at(ctx, .LBRACKET) { left = _parse_subscript(ctx, left) }
	}

	return left
}

_consume_newline :: proc(ctx: ^Parser_Context) {
	if _at(ctx, .NEWLINE) { _advance(ctx) }
	if _at(ctx, .SEMICOLON) { _advance(ctx) }
}

_parse_unexpected_indent :: proc(ctx: ^Parser_Context) -> Stmt {
	_advance(ctx) // skip unexpected INDENT
	return nil
}

// ==================== Function / Class ====================

_parse_func_def :: proc(ctx: ^Parser_Context, is_async: bool) -> Stmt {
	def_tok := _advance(ctx) // consume 'def'
	name_tok := _advance(ctx) // function name

	// Parameters
	args := _parse_parameters(ctx)

	// Return annotation
	returns: Expr
	if _at(ctx, .ARROW) {
		_advance(ctx)
		returns = parse_expr(ctx)
	}

	_expect(ctx, .COLON)
	body := _parse_block(ctx)

	if is_async {
		n := new(Async_Func_Def, ctx.allocator)
		n.loc = def_tok.loc
		n.name = name_tok.text
		n.args = args
		n.body = body
		n.returns = returns
		return n
	}

	n := new(Func_Def, ctx.allocator)
	n.loc = def_tok.loc
	n.name = name_tok.text
	n.args = args
	n.body = body
	n.returns = returns
	return n
}

_parse_parameters :: proc(ctx: ^Parser_Context) -> Arguments {
	args: Arguments
	_expect(ctx, .LPAREN)

	posonly := make([dynamic]Arg, 0, 4, ctx.allocator)
	regular := make([dynamic]Arg, 0, 4, ctx.allocator)
	kwonly := make([dynamic]Arg, 0, 2, ctx.allocator)
	defaults := make([dynamic]Expr, 0, 4, ctx.allocator)
	kw_defaults := make([dynamic]Expr, 0, 2, ctx.allocator)
	seen_star := false
	seen_slash := false

	for !_at(ctx, .RPAREN) && !_at(ctx, .EOF) {
		if len(posonly) > 0 || len(regular) > 0 || len(kwonly) > 0 || seen_star || seen_slash {
			if !_at(ctx, .COMMA) { break }
			_advance(ctx)
			if _at(ctx, .RPAREN) { break }
		}

		// /  (positional-only marker)
		if _at(ctx, .SLASH) {
			_advance(ctx)
			// Move all regular params to posonly
			for p in regular { append(&posonly, p) }
			clear(&regular)
			seen_slash = true
			continue
		}

		// * or *args
		if _at(ctx, .STAR) {
			_advance(ctx)
			seen_star = true
			if _at_any(ctx, .NAME, .KW_MATCH, .KW_CASE, .KW_TYPE) {
				tok := _advance(ctx)
				ann: Expr
				if _at(ctx, .COLON) {
					_advance(ctx)
					ann = parse_expr(ctx)
				}
				va := new(Arg, ctx.allocator)
				va.loc = tok.loc
				va.arg = tok.text
				va.annotation = ann
				args.vararg = va
			}
			continue
		}

		// **kwargs
		if _at(ctx, .DOUBLE_STAR) {
			_advance(ctx)
			if _at_any(ctx, .NAME, .KW_MATCH, .KW_CASE, .KW_TYPE) {
				tok := _advance(ctx)
				ann: Expr
				if _at(ctx, .COLON) {
					_advance(ctx)
					ann = parse_expr(ctx)
				}
				kw := new(Arg, ctx.allocator)
				kw.loc = tok.loc
				kw.arg = tok.text
				kw.annotation = ann
				args.kwarg = kw
			}
			continue
		}

		// Regular parameter
		if _at_any(ctx, .NAME, .KW_MATCH, .KW_CASE, .KW_TYPE) {
			tok := _advance(ctx)
			ann: Expr
			if _at(ctx, .COLON) {
				_advance(ctx)
				ann = parse_expr(ctx)
			}
			param := Arg{loc = tok.loc, arg = tok.text, annotation = ann}

			// Default value
			has_default := false
			if _at(ctx, .ASSIGN) {
				_advance(ctx)
				default_val := parse_expr(ctx)
				has_default = true
				if seen_star {
					append(&kw_defaults, default_val)
				} else {
					append(&defaults, default_val)
				}
			} else if seen_star {
				append(&kw_defaults, Expr(nil))
			}

			if seen_star {
				append(&kwonly, param)
			} else {
				append(&regular, param)
			}
		} else {
			break
		}
	}

	_expect(ctx, .RPAREN)

	args.posonlyargs = posonly[:]
	args.args = regular[:]
	args.kwonlyargs = kwonly[:]
	args.defaults = defaults[:]
	args.kw_defaults = kw_defaults[:]
	return args
}

_parse_class_def :: proc(ctx: ^Parser_Context) -> Stmt {
	class_tok := _advance(ctx) // consume 'class'
	name_tok := _advance(ctx)

	bases: []Expr
	keywords: []Keyword
	if _at(ctx, .LPAREN) {
		_advance(ctx)
		b := make([dynamic]Expr, 0, 2, ctx.allocator)
		kw := make([dynamic]Keyword, 0, 2, ctx.allocator)
		for !_at(ctx, .RPAREN) && !_at(ctx, .EOF) {
			if len(b) > 0 || len(kw) > 0 {
				if !_at(ctx, .COMMA) { break }
				_advance(ctx)
				if _at(ctx, .RPAREN) { break }
			}
			// keyword argument: metaclass=type
			if (_at_any(ctx, .NAME, .KW_MATCH, .KW_CASE, .KW_TYPE)) && ctx.pos + 1 < len(ctx.tokens) && ctx.tokens[ctx.pos + 1].kind == .ASSIGN {
				n := _advance(ctx)
				_advance(ctx) // =
				v := parse_expr(ctx)
				append(&kw, Keyword{arg = n.text, value = v, loc = n.loc})
			} else if _at(ctx, .DOUBLE_STAR) {
				_advance(ctx)
				v := parse_expr(ctx)
				append(&kw, Keyword{arg = "", value = v})
			} else {
				e := parse_expr(ctx)
				if e != nil { append(&b, e) }
			}
		}
		_expect(ctx, .RPAREN)
		bases = b[:]
		keywords = kw[:]
	}

	_expect(ctx, .COLON)
	body := _parse_block(ctx)

	n := new(Class_Def, ctx.allocator)
	n.loc = class_tok.loc
	n.name = name_tok.text
	n.bases = bases
	n.keywords = keywords
	n.body = body
	return n
}

// ==================== Control Flow ====================

_parse_if :: proc(ctx: ^Parser_Context) -> Stmt {
	if_tok := _advance(ctx) // consume 'if'
	test := parse_expr_list(ctx)
	_expect(ctx, .COLON)
	body := _parse_block(ctx)

	orelse: []Stmt
	_skip_newlines(ctx)
	if _at(ctx, .KW_ELIF) {
		// elif → nested If_Stmt in orelse
		elif_stmt := _parse_if(ctx)
		orelse_arr := make([]Stmt, 1, ctx.allocator)
		orelse_arr[0] = elif_stmt
		orelse = orelse_arr
	} else if _at(ctx, .KW_ELSE) {
		_advance(ctx)
		_expect(ctx, .COLON)
		orelse = _parse_block(ctx)
	}

	n := new(If_Stmt, ctx.allocator)
	n.loc = if_tok.loc
	n.test = test
	n.body = body
	n.orelse = orelse
	return n
}

_parse_while :: proc(ctx: ^Parser_Context) -> Stmt {
	tok := _advance(ctx)
	test := parse_expr_list(ctx)
	_expect(ctx, .COLON)
	body := _parse_block(ctx)

	orelse: []Stmt
	_skip_newlines(ctx)
	if _at(ctx, .KW_ELSE) {
		_advance(ctx)
		_expect(ctx, .COLON)
		orelse = _parse_block(ctx)
	}

	n := new(While_Stmt, ctx.allocator)
	n.loc = tok.loc
	n.test = test
	n.body = body
	n.orelse = orelse
	return n
}

_parse_for :: proc(ctx: ^Parser_Context, is_async: bool) -> Stmt {
	tok := _advance(ctx) // consume 'for'
	target := _parse_target_list(ctx) // don't consume 'in' as comparison
	_expect(ctx, .KW_IN)
	iter := parse_expr_list(ctx)
	_expect(ctx, .COLON)
	body := _parse_block(ctx)

	orelse: []Stmt
	_skip_newlines(ctx)
	if _at(ctx, .KW_ELSE) {
		_advance(ctx)
		_expect(ctx, .COLON)
		orelse = _parse_block(ctx)
	}

	if is_async {
		n := new(Async_For, ctx.allocator)
		n.loc = tok.loc
		n.target = target
		n.iter = iter
		n.body = body
		n.orelse = orelse
		return n
	}

	n := new(For_Stmt, ctx.allocator)
	n.loc = tok.loc
	n.target = target
	n.iter = iter
	n.body = body
	n.orelse = orelse
	return n
}

_parse_with :: proc(ctx: ^Parser_Context, is_async: bool) -> Stmt {
	tok := _advance(ctx) // consume 'with'

	items := make([dynamic]With_Item, 0, 2, ctx.allocator)
	for {
		ctx_expr := parse_expr(ctx)
		var: Expr
		if _at(ctx, .KW_AS) {
			_advance(ctx)
			var = parse_expr(ctx)
		}
		append(&items, With_Item{context_expr = ctx_expr, optional_vars = var})
		if !_at(ctx, .COMMA) { break }
		_advance(ctx)
	}

	_expect(ctx, .COLON)
	body := _parse_block(ctx)

	if is_async {
		n := new(Async_With, ctx.allocator)
		n.loc = tok.loc
		n.items = items[:]
		n.body = body
		return n
	}

	n := new(With_Stmt, ctx.allocator)
	n.loc = tok.loc
	n.items = items[:]
	n.body = body
	return n
}

_parse_try :: proc(ctx: ^Parser_Context) -> Stmt {
	tok := _advance(ctx) // consume 'try'
	_expect(ctx, .COLON)
	body := _parse_block(ctx)

	handlers := make([dynamic]Exception_Handler, 0, 2, ctx.allocator)
	orelse: []Stmt
	finalbody: []Stmt
	is_star := false

	_skip_newlines(ctx)
	for _at(ctx, .KW_EXCEPT) {
		_advance(ctx) // consume 'except'

		// except* for exception groups
		if _at(ctx, .STAR) {
			is_star = true
			_advance(ctx)
		}

		h: Exception_Handler
		h.loc = tok.loc

		if !_at(ctx, .COLON) {
			h.type = parse_expr(ctx)
			if _at(ctx, .KW_AS) {
				_advance(ctx)
				name_tok := _advance(ctx)
				h.name = name_tok.text
			}
		}

		_expect(ctx, .COLON)
		h.body = _parse_block(ctx)
		append(&handlers, h)
		_skip_newlines(ctx)
	}

	_skip_newlines(ctx)
	if _at(ctx, .KW_ELSE) {
		_advance(ctx)
		_expect(ctx, .COLON)
		orelse = _parse_block(ctx)
	}

	_skip_newlines(ctx)
	if _at(ctx, .KW_FINALLY) {
		_advance(ctx)
		_expect(ctx, .COLON)
		finalbody = _parse_block(ctx)
	}

	if is_star {
		n := new(Try_Star, ctx.allocator)
		n.loc = tok.loc
		n.body = body
		n.handlers = handlers[:]
		n.orelse = orelse
		n.finalbody = finalbody
		return n
	}

	n := new(Try_Stmt, ctx.allocator)
	n.loc = tok.loc
	n.body = body
	n.handlers = handlers[:]
	n.orelse = orelse
	n.finalbody = finalbody
	return n
}

_parse_match_or_expr :: proc(ctx: ^Parser_Context) -> Stmt {
	// 'match' is a soft keyword. It's a match statement if followed by expr + :
	// Otherwise it's an expression statement
	saved_pos := ctx.pos
	tok := _advance(ctx) // consume 'match'

	// Try to parse as match statement
	subject := parse_expr_list(ctx)
	if _at(ctx, .COLON) {
		_advance(ctx)
		// It's a match statement
		cases := _parse_match_cases(ctx)
		n := new(Match_Stmt, ctx.allocator)
		n.loc = tok.loc
		n.subject = subject
		n.cases = cases
		return n
	}

	// Not a match statement — treat 'match' as identifier and reparse
	ctx.pos = saved_pos
	return _parse_expr_or_assign(ctx)
}

_parse_match_cases :: proc(ctx: ^Parser_Context) -> []Match_Case {
	cases := make([dynamic]Match_Case, 0, 4, ctx.allocator)
	_skip_newlines(ctx)
	if _at(ctx, .INDENT) { _advance(ctx) }

	for _at(ctx, .KW_CASE) {
		_skip_newlines(ctx)
		if !_at(ctx, .KW_CASE) { break }
		_advance(ctx) // consume 'case'

		pattern := _parse_pattern(ctx)
		guard: Expr
		if _at(ctx, .KW_IF) {
			_advance(ctx)
			guard = parse_expr(ctx)
		}
		_expect(ctx, .COLON)
		body := _parse_block(ctx)

		append(&cases, Match_Case{
			pattern = pattern,
			guard   = guard,
			body    = body,
		})
		_skip_newlines(ctx)
	}

	if _at(ctx, .DEDENT) { _advance(ctx) }
	return cases[:]
}

_parse_pattern :: proc(ctx: ^Parser_Context) -> Pattern {
	// Simplified pattern parsing — covers common cases
	tok := _peek(ctx)

	#partial switch tok.kind {
	case .STAR:
		_advance(ctx)
		if _at_any(ctx, .NAME, .KW_MATCH, .KW_CASE, .KW_TYPE) {
			name_tok := _advance(ctx)
			p := new(Match_Star, ctx.allocator)
			p.loc = tok.loc
			p.name = name_tok.text
			return p
		}
		p := new(Match_Star, ctx.allocator)
		p.loc = tok.loc
		return p
	case .KW_NONE:
		_advance(ctx)
		p := new(Match_Singleton, ctx.allocator)
		p.loc = tok.loc
		p.value = Const_None{}
		return p
	case .KW_TRUE:
		_advance(ctx)
		p := new(Match_Singleton, ctx.allocator)
		p.loc = tok.loc
		p.value = true
		return p
	case .KW_FALSE:
		_advance(ctx)
		p := new(Match_Singleton, ctx.allocator)
		p.loc = tok.loc
		p.value = false
		return p
	case .INT, .FLOAT, .STRING, .MINUS:
		val := parse_expr(ctx)
		p := new(Match_Value, ctx.allocator)
		p.loc = tok.loc
		p.value = val
		return p
	case .LBRACKET:
		_advance(ctx)
		patterns := make([dynamic]Pattern, 0, 4, ctx.allocator)
		for !_at(ctx, .RBRACKET) && !_at(ctx, .EOF) {
			if len(patterns) > 0 { _expect(ctx, .COMMA) }
			if _at(ctx, .RBRACKET) { break }
			append(&patterns, _parse_pattern(ctx))
		}
		_expect(ctx, .RBRACKET)
		p := new(Match_Sequence, ctx.allocator)
		p.loc = tok.loc
		p.patterns = patterns[:]
		return p
	case .NAME, .KW_MATCH, .KW_CASE, .KW_TYPE:
		_advance(ctx)
		// Check for 'as' pattern
		if _at(ctx, .KW_AS) {
			_advance(ctx)
			name_tok := _advance(ctx)
			inner := new(Match_Value, ctx.allocator)
			inner.loc = tok.loc
			inner_name := new(Name_Expr, ctx.allocator)
			inner_name.id = tok.text
			inner_name.loc = tok.loc
			inner.value = inner_name
			p := new(Match_As, ctx.allocator)
			p.loc = tok.loc
			p.pattern = inner
			p.name = name_tok.text
			return p
		}
		// Wildcard _
		if tok.text == "_" {
			p := new(Match_As, ctx.allocator)
			p.loc = tok.loc
			return p
		}
		// Capture pattern (just a name)
		p := new(Match_As, ctx.allocator)
		p.loc = tok.loc
		p.name = tok.text
		return p
	}

	// Fallback
	val := parse_expr(ctx)
	p := new(Match_Value, ctx.allocator)
	p.loc = tok.loc
	p.value = val
	return p
}

// ==================== Simple Statements ====================

_parse_return :: proc(ctx: ^Parser_Context) -> Stmt {
	tok := _advance(ctx)
	value: Expr
	if !_at_any(ctx, .NEWLINE, .EOF, .SEMICOLON, .DEDENT) {
		value = parse_expr_list(ctx)
	}
	_consume_newline(ctx)
	n := new(Return_Stmt, ctx.allocator)
	n.loc = tok.loc
	n.value = value
	return n
}

_parse_del :: proc(ctx: ^Parser_Context) -> Stmt {
	tok := _advance(ctx)
	targets := make([dynamic]Expr, 0, 2, ctx.allocator)
	for {
		e := parse_expr(ctx)
		if e != nil { append(&targets, e) }
		if !_at(ctx, .COMMA) { break }
		_advance(ctx)
	}
	_consume_newline(ctx)
	n := new(Delete_Stmt, ctx.allocator)
	n.loc = tok.loc
	n.targets = targets[:]
	return n
}

_parse_raise :: proc(ctx: ^Parser_Context) -> Stmt {
	tok := _advance(ctx)
	exc: Expr
	cause: Expr
	if !_at_any(ctx, .NEWLINE, .EOF, .SEMICOLON) {
		exc = parse_expr(ctx)
		if _at(ctx, .KW_FROM) {
			_advance(ctx)
			cause = parse_expr(ctx)
		}
	}
	_consume_newline(ctx)
	n := new(Raise_Stmt, ctx.allocator)
	n.loc = tok.loc
	n.exc = exc
	n.cause = cause
	return n
}

_parse_assert :: proc(ctx: ^Parser_Context) -> Stmt {
	tok := _advance(ctx)
	test := parse_expr(ctx)
	msg: Expr
	if _at(ctx, .COMMA) {
		_advance(ctx)
		msg = parse_expr(ctx)
	}
	_consume_newline(ctx)
	n := new(Assert_Stmt, ctx.allocator)
	n.loc = tok.loc
	n.test = test
	n.msg = msg
	return n
}

_parse_global :: proc(ctx: ^Parser_Context) -> Stmt {
	tok := _advance(ctx)
	names := make([dynamic]string, 0, 4, ctx.allocator)
	for {
		if _at_any(ctx, .NAME, .KW_MATCH, .KW_CASE, .KW_TYPE) {
			name_tok := _advance(ctx)
			append(&names, name_tok.text)
		} else { break }
		if !_at(ctx, .COMMA) { break }
		_advance(ctx)
	}
	_consume_newline(ctx)
	n := new(Global_Stmt, ctx.allocator)
	n.loc = tok.loc
	n.names = names[:]
	return n
}

_parse_nonlocal :: proc(ctx: ^Parser_Context) -> Stmt {
	tok := _advance(ctx)
	names := make([dynamic]string, 0, 4, ctx.allocator)
	for {
		if _at_any(ctx, .NAME, .KW_MATCH, .KW_CASE, .KW_TYPE) {
			name_tok := _advance(ctx)
			append(&names, name_tok.text)
		} else { break }
		if !_at(ctx, .COMMA) { break }
		_advance(ctx)
	}
	_consume_newline(ctx)
	n := new(Nonlocal_Stmt, ctx.allocator)
	n.loc = tok.loc
	n.names = names[:]
	return n
}

// ==================== Imports ====================

_parse_import :: proc(ctx: ^Parser_Context) -> Stmt {
	tok := _advance(ctx) // consume 'import'
	aliases := make([dynamic]Alias, 0, 2, ctx.allocator)

	for {
		name := _parse_dotted_name(ctx)
		asname := ""
		if _at(ctx, .KW_AS) {
			_advance(ctx)
			as_tok := _advance(ctx)
			asname = as_tok.text
		}
		append(&aliases, Alias{name = name, asname = asname})
		if !_at(ctx, .COMMA) { break }
		_advance(ctx)
	}
	_consume_newline(ctx)

	n := new(Import_Stmt, ctx.allocator)
	n.loc = tok.loc
	n.names = aliases[:]
	return n
}

_parse_from_import :: proc(ctx: ^Parser_Context) -> Stmt {
	tok := _advance(ctx) // consume 'from'

	level := 0
	for _at(ctx, .DOT) || _at(ctx, .ELLIPSIS) {
		if _at(ctx, .ELLIPSIS) {
			level += 3
			_advance(ctx)
		} else {
			level += 1
			_advance(ctx)
		}
	}

	module_name := ""
	if _at_any(ctx, .NAME, .KW_MATCH, .KW_CASE, .KW_TYPE) {
		module_name = _parse_dotted_name(ctx)
	}

	_expect(ctx, .KW_IMPORT)

	aliases := make([dynamic]Alias, 0, 4, ctx.allocator)
	if _at(ctx, .STAR) {
		_advance(ctx)
		append(&aliases, Alias{name = "*"})
	} else {
		paren := false
		if _at(ctx, .LPAREN) { _advance(ctx); paren = true; _skip_newlines(ctx) }
		for {
			_skip_newlines(ctx)
			if _at_any(ctx, .RPAREN, .NEWLINE, .EOF) { break }
			name_tok := _advance(ctx)
			asname := ""
			if _at(ctx, .KW_AS) {
				_advance(ctx)
				as_tok := _advance(ctx)
				asname = as_tok.text
			}
			append(&aliases, Alias{name = name_tok.text, asname = asname})
			if !_at(ctx, .COMMA) { break }
			_advance(ctx)
			_skip_newlines(ctx)
		}
		if paren { _expect(ctx, .RPAREN) }
	}

	_consume_newline(ctx)

	n := new(Import_From, ctx.allocator)
	n.loc = tok.loc
	n.module = module_name
	n.names = aliases[:]
	n.level = level
	return n
}

_parse_dotted_name :: proc(ctx: ^Parser_Context) -> string {
	parts := make([dynamic]string, 0, 3, ctx.allocator)
	if _at_any(ctx, .NAME, .KW_MATCH, .KW_CASE, .KW_TYPE) {
		append(&parts, _advance(ctx).text)
	}
	for _at(ctx, .DOT) {
		_advance(ctx)
		if _at_any(ctx, .NAME, .KW_MATCH, .KW_CASE, .KW_TYPE) {
			append(&parts, _advance(ctx).text)
		}
	}
	return strings.join(parts[:], ".", ctx.allocator)
}

// ==================== Async ====================

_parse_async :: proc(ctx: ^Parser_Context) -> Stmt {
	_advance(ctx) // consume 'async'
	tok := _peek(ctx)
	#partial switch tok.kind {
	case .KW_DEF:  return _parse_func_def(ctx, true)
	case .KW_FOR:  return _parse_for(ctx, true)
	case .KW_WITH: return _parse_with(ctx, true)
	}
	// async used as expression (unlikely but handle gracefully)
	return _parse_expr_or_assign(ctx)
}

// ==================== Decorators ====================

_parse_decorated :: proc(ctx: ^Parser_Context) -> Stmt {
	decorators := make([dynamic]Expr, 0, 2, ctx.allocator)
	for _at(ctx, .AT) {
		_advance(ctx) // consume @
		dec := parse_expr(ctx)
		append(&decorators, dec)
		_consume_newline(ctx)
		_skip_newlines(ctx)
	}

	stmt := _parse_stmt(ctx)

	// Attach decorators
	#partial switch s in stmt {
	case ^Func_Def:
		s.decorator_list = decorators[:]
	case ^Async_Func_Def:
		s.decorator_list = decorators[:]
	case ^Class_Def:
		s.decorator_list = decorators[:]
	}

	return stmt
}

// ==================== Type Alias ====================

_parse_type_alias_or_expr :: proc(ctx: ^Parser_Context) -> Stmt {
	// 'type' is a soft keyword (3.12+). Statement if: type Name = expr
	saved_pos := ctx.pos
	tok := _advance(ctx) // consume 'type'

	if _at_any(ctx, .NAME, .KW_MATCH, .KW_CASE) {
		name_tok := _peek(ctx)
		_advance(ctx)
		if _at(ctx, .ASSIGN) {
			_advance(ctx)
			value := parse_expr(ctx)
			_consume_newline(ctx)
			name_expr := new(Name_Expr, ctx.allocator)
			name_expr.loc = name_tok.loc
			name_expr.id = name_tok.text
			n := new(Type_Alias_Stmt, ctx.allocator)
			n.loc = tok.loc
			n.name = name_expr
			n.value = value
			return n
		}
	}

	// Not a type alias — reparse as expression
	ctx.pos = saved_pos
	return _parse_expr_or_assign(ctx)
}

// ==================== Expression/Assignment Statement ====================

_parse_expr_or_assign :: proc(ctx: ^Parser_Context) -> Stmt {
	loc := _peek(ctx).loc
	left := parse_expr_list(ctx)
	if left == nil {
		// Skip unparseable token
		_advance(ctx)
		return nil
	}

	// Augmented assignment: +=, -=, etc.
	aug_op, is_aug := _check_aug_assign(ctx)
	if is_aug {
		_advance(ctx) // consume op=
		value := parse_expr_list(ctx)
		_consume_newline(ctx)
		n := new(Aug_Assign, ctx.allocator)
		n.loc = loc
		n.target = left
		n.op = aug_op
		n.value = value
		return n
	}

	// Annotation: x: type or x: type = value
	if _at(ctx, .COLON) {
		_advance(ctx)
		annotation := parse_expr(ctx)
		value: Expr
		if _at(ctx, .ASSIGN) {
			_advance(ctx)
			value = parse_expr_list(ctx)
		}
		_consume_newline(ctx)
		n := new(Ann_Assign, ctx.allocator)
		n.loc = loc
		n.target = left
		n.annotation = annotation
		n.value = value
		n.simple = true
		return n
	}

	// Simple assignment: x = value (possibly chained: a = b = value)
	if _at(ctx, .ASSIGN) {
		targets := make([dynamic]Expr, 0, 2, ctx.allocator)
		append(&targets, left)

		for _at(ctx, .ASSIGN) {
			_advance(ctx)
			next := parse_expr_list(ctx)
			append(&targets, next)
		}

		// Last element is the value, rest are targets
		value := targets[len(targets) - 1]
		tgts := targets[:len(targets) - 1]

		_consume_newline(ctx)
		n := new(Assign, ctx.allocator)
		n.loc = loc
		n.targets = tgts[:]
		n.value = value
		return n
	}

	// Expression statement
	_consume_newline(ctx)
	n := new(Expr_Stmt, ctx.allocator)
	n.loc = loc
	n.value = left
	return n
}

_check_aug_assign :: proc(ctx: ^Parser_Context) -> (Binary_Op, bool) {
	kind := _peek_kind(ctx)
	#partial switch kind {
	case .PLUS_EQ:         return .Add, true
	case .MINUS_EQ:        return .Sub, true
	case .STAR_EQ:         return .Mult, true
	case .SLASH_EQ:        return .Div, true
	case .DOUBLE_SLASH_EQ: return .Floor_Div, true
	case .PERCENT_EQ:      return .Mod, true
	case .AT_EQ:           return .Mat_Mult, true
	case .AMPERSAND_EQ:    return .Bit_And, true
	case .PIPE_EQ:         return .Bit_Or, true
	case .CARET_EQ:        return .Bit_Xor, true
	case .LSHIFT_EQ:       return .LShift, true
	case .RSHIFT_EQ:       return .RShift, true
	case .DOUBLE_STAR_EQ:  return .Pow, true
	}
	return .Add, false
}
