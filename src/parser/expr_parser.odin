package parser

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:strconv"

// ==================== Parser Context ====================

Parser_Context :: struct {
	tokens:    []Token,
	pos:       int,
	allocator: mem.Allocator,
	file:      string,
}

// ==================== Token Helpers ====================

_peek :: proc(ctx: ^Parser_Context) -> Token {
	if ctx.pos >= len(ctx.tokens) { return Token{kind = .EOF} }
	return ctx.tokens[ctx.pos]
}

_peek_kind :: proc(ctx: ^Parser_Context) -> Token_Kind {
	if ctx.pos >= len(ctx.tokens) { return .EOF }
	return ctx.tokens[ctx.pos].kind
}

_advance :: proc(ctx: ^Parser_Context) -> Token {
	if ctx.pos >= len(ctx.tokens) { return Token{kind = .EOF} }
	tok := ctx.tokens[ctx.pos]
	ctx.pos += 1
	return tok
}

_expect :: proc(ctx: ^Parser_Context, kind: Token_Kind) -> (Token, bool) {
	tok := _peek(ctx)
	if tok.kind != kind { return tok, false }
	return _advance(ctx), true
}

_at :: proc(ctx: ^Parser_Context, kind: Token_Kind) -> bool {
	return _peek_kind(ctx) == kind
}

_at_any :: proc(ctx: ^Parser_Context, kinds: ..Token_Kind) -> bool {
	k := _peek_kind(ctx)
	for kind in kinds {
		if k == kind { return true }
	}
	return false
}

_skip_newlines :: proc(ctx: ^Parser_Context) {
	for _at(ctx, .NEWLINE) { _advance(ctx) }
}

// ==================== Precedence ====================

// Pratt parser precedence levels
PREC_NONE      :: 0
PREC_LAMBDA    :: 1
PREC_TERNARY   :: 2
PREC_OR        :: 3
PREC_AND       :: 4
PREC_NOT       :: 5
PREC_CMP       :: 6
PREC_BIT_OR    :: 7
PREC_BIT_XOR   :: 8
PREC_BIT_AND   :: 9
PREC_SHIFT     :: 10
PREC_ADD       :: 11
PREC_MUL       :: 12
PREC_UNARY     :: 13
PREC_POWER     :: 14
PREC_AWAIT     :: 15
PREC_POSTFIX   :: 16

_infix_prec :: proc(kind: Token_Kind) -> int {
	#partial switch kind {
	case .KW_IF:        return PREC_TERNARY
	case .KW_OR:        return PREC_OR
	case .KW_AND:       return PREC_AND
	case .PIPE:         return PREC_BIT_OR
	case .CARET:        return PREC_BIT_XOR
	case .AMPERSAND:    return PREC_BIT_AND
	case .LSHIFT, .RSHIFT: return PREC_SHIFT
	case .PLUS, .MINUS: return PREC_ADD
	case .STAR, .SLASH, .DOUBLE_SLASH, .PERCENT, .AT: return PREC_MUL
	case .DOUBLE_STAR:  return PREC_POWER
	// Comparisons
	case .LT, .GT, .LE, .GE, .EQ_EQ, .NOT_EQ, .KW_IN, .KW_IS, .KW_NOT: return PREC_CMP
	// Postfix
	case .LPAREN, .LBRACKET, .DOT: return PREC_POSTFIX
	// Walrus
	case .WALRUS:       return PREC_LAMBDA
	}
	return PREC_NONE
}

// ==================== Expression Parser (Pratt) ====================

parse_expr :: proc(ctx: ^Parser_Context, min_prec: int = 0) -> Expr {
	left := _parse_prefix(ctx)
	if left == nil { return nil }

	for {
		prec := _infix_prec(_peek_kind(ctx))
		if prec <= min_prec { break }

		left = _parse_infix(ctx, left, prec)
		if left == nil { break }
	}

	return left
}

// Parse a comma-separated expression list (for tuples, function args)
parse_expr_list :: proc(ctx: ^Parser_Context) -> Expr {
	first := parse_expr(ctx)
	if first == nil { return nil }

	if !_at(ctx, .COMMA) { return first }

	// Tuple
	loc := _expr_loc(first)
	elts := make([dynamic]Expr, 0, 4, ctx.allocator)
	append(&elts, first)

	for _at(ctx, .COMMA) {
		_advance(ctx) // consume ,
		if _at_any(ctx, .RPAREN, .RBRACKET, .RBRACE, .NEWLINE, .EOF, .COLON) { break }
		e := parse_expr(ctx)
		if e != nil { append(&elts, e) }
	}

	t := new(Tuple_Expr, ctx.allocator)
	t.loc = loc
	t.elts = elts[:]
	t.ctx = .Load
	return t
}

// ==================== Prefix (NUD) ====================

_parse_prefix :: proc(ctx: ^Parser_Context) -> Expr {
	tok := _peek(ctx)

	#partial switch tok.kind {
	case .INT, .FLOAT, .COMPLEX:
		return _parse_number(ctx)
	case .STRING, .BYTES:
		return _parse_string_constant(ctx)
	case .FSTRING:
		return _parse_fstring(ctx)
	case .KW_TRUE:
		_advance(ctx)
		return _make_const_bool(ctx, true, tok.loc)
	case .KW_FALSE:
		_advance(ctx)
		return _make_const_bool(ctx, false, tok.loc)
	case .KW_NONE:
		_advance(ctx)
		return _make_const_none(ctx, tok.loc)
	case .NAME, .KW_MATCH, .KW_CASE, .KW_TYPE:
		// match/case/type are soft keywords — valid as identifiers
		_advance(ctx)
		n := new(Name_Expr, ctx.allocator)
		n.loc = tok.loc
		n.id = tok.text
		n.ctx = .Load
		return n
	case .LPAREN:
		return _parse_paren_expr(ctx)
	case .LBRACKET:
		return _parse_list_or_listcomp(ctx)
	case .LBRACE:
		return _parse_dict_or_set(ctx)
	case .MINUS, .PLUS, .TILDE:
		return _parse_unary(ctx)
	case .KW_NOT:
		return _parse_not(ctx)
	case .KW_LAMBDA:
		return _parse_lambda(ctx)
	case .KW_AWAIT:
		return _parse_await(ctx)
	case .KW_YIELD:
		return _parse_yield(ctx)
	case .STAR:
		return _parse_starred(ctx)
	case .ELLIPSIS:
		_advance(ctx)
		c := new(Constant_Expr, ctx.allocator)
		c.loc = tok.loc
		c.value = Const_Ellipsis{}
		return c
	}

	return nil
}

// ==================== Infix (LED) ====================

_parse_infix :: proc(ctx: ^Parser_Context, left: Expr, prec: int) -> Expr {
	tok := _peek(ctx)

	#partial switch tok.kind {
	// Binary operators
	case .PLUS, .MINUS, .STAR, .SLASH, .DOUBLE_SLASH, .PERCENT, .AT,
	     .PIPE, .CARET, .AMPERSAND, .LSHIFT, .RSHIFT:
		return _parse_binop(ctx, left, prec)
	case .DOUBLE_STAR:
		return _parse_binop_right(ctx, left, prec) // right-associative
	// Boolean
	case .KW_AND:
		return _parse_boolop(ctx, left, .And)
	case .KW_OR:
		return _parse_boolop(ctx, left, .Or)
	// Comparison (chained)
	case .LT, .GT, .LE, .GE, .EQ_EQ, .NOT_EQ, .KW_IN, .KW_IS, .KW_NOT:
		return _parse_comparison(ctx, left)
	// Ternary
	case .KW_IF:
		return _parse_ternary(ctx, left)
	// Walrus
	case .WALRUS:
		return _parse_walrus(ctx, left)
	// Postfix
	case .LPAREN:
		return _parse_call(ctx, left)
	case .LBRACKET:
		return _parse_subscript(ctx, left)
	case .DOT:
		return _parse_attribute(ctx, left)
	}

	return left
}

// ==================== Prefix Implementations ====================

_parse_number :: proc(ctx: ^Parser_Context) -> Expr {
	tok := _advance(ctx)
	c := new(Constant_Expr, ctx.allocator)
	c.loc = tok.loc

	#partial switch tok.kind {
	case .INT:
		// Parse integer, handling 0x, 0o, 0b, underscores
		text := tok.text
		clean, _ := strings.replace_all(text, "_", "", ctx.allocator)
		val, ok := strconv.parse_i64_of_base(clean, 0)
		if ok { c.value = val } else { c.value = i64(0) }
	case .FLOAT:
		text, _ := strings.replace_all(tok.text, "_", "", ctx.allocator)
		val, ok := strconv.parse_f64(text)
		if ok { c.value = val } else { c.value = f64(0) }
	case .COMPLEX:
		text, _ := strings.replace_all(tok.text, "_", "", ctx.allocator)
		// Remove trailing j/J
		if len(text) > 0 && (text[len(text)-1] == 'j' || text[len(text)-1] == 'J') {
			text = text[:len(text)-1]
		}
		val, ok := strconv.parse_f64(text)
		if ok { c.value = Const_Complex{imag = val} } else { c.value = Const_Complex{} }
	case: // unreachable
	}
	return c
}

_parse_string_constant :: proc(ctx: ^Parser_Context) -> Expr {
	tok := _advance(ctx)
	c := new(Constant_Expr, ctx.allocator)
	c.loc = tok.loc

	// Extract string content (strip quotes and prefix)
	content := _extract_string_content(tok.text, ctx.allocator)
	if tok.kind == .BYTES {
		c.value = Const_Bytes{data = transmute([]u8)content}
	} else {
		c.value = content
	}
	return c
}

_parse_fstring :: proc(ctx: ^Parser_Context) -> Expr {
	tok := _advance(ctx)
	// For now, treat f-string as a JoinedStr with the raw text
	// Full f-string expression parsing is deferred
	js := new(Joined_Str, ctx.allocator)
	js.loc = tok.loc
	js.values = nil // simplified — downstream handles raw text
	return js
}

_parse_paren_expr :: proc(ctx: ^Parser_Context) -> Expr {
	open := _advance(ctx) // consume (

	// Empty tuple
	if _at(ctx, .RPAREN) {
		_advance(ctx)
		t := new(Tuple_Expr, ctx.allocator)
		t.loc = open.loc
		t.elts = nil
		t.ctx = .Load
		return t
	}

	// Generator expression check: expr for ...
	// Or comprehension: (x for x in ...)
	first := parse_expr(ctx)

	if _at(ctx, .KW_FOR) {
		// Generator expression
		gen := _parse_comprehension_tail(ctx, first, open.loc)
		_expect(ctx, .RPAREN)
		return gen
	}

	if _at(ctx, .COMMA) {
		// Tuple
		elts := make([dynamic]Expr, 0, 4, ctx.allocator)
		append(&elts, first)
		for _at(ctx, .COMMA) {
			_advance(ctx)
			if _at(ctx, .RPAREN) { break }
			e := parse_expr(ctx)
			if e != nil { append(&elts, e) }
		}
		_expect(ctx, .RPAREN)
		t := new(Tuple_Expr, ctx.allocator)
		t.loc = open.loc
		t.elts = elts[:]
		t.ctx = .Load
		return t
	}

	// Parenthesized expression
	_expect(ctx, .RPAREN)
	return first
}

_parse_list_or_listcomp :: proc(ctx: ^Parser_Context) -> Expr {
	open := _advance(ctx) // consume [

	if _at(ctx, .RBRACKET) {
		_advance(ctx)
		l := new(List_Expr, ctx.allocator)
		l.loc = open.loc
		l.elts = nil
		l.ctx = .Load
		return l
	}

	first := parse_expr(ctx)

	// List comprehension
	if _at(ctx, .KW_FOR) {
		comp := _parse_list_comp(ctx, first, open.loc)
		_expect(ctx, .RBRACKET)
		return comp
	}

	// Regular list
	elts := make([dynamic]Expr, 0, 4, ctx.allocator)
	append(&elts, first)
	for _at(ctx, .COMMA) {
		_advance(ctx)
		if _at(ctx, .RBRACKET) { break }
		e := parse_expr(ctx)
		if e != nil { append(&elts, e) }
	}
	_expect(ctx, .RBRACKET)
	l := new(List_Expr, ctx.allocator)
	l.loc = open.loc
	l.elts = elts[:]
	l.ctx = .Load
	return l
}

_parse_dict_or_set :: proc(ctx: ^Parser_Context) -> Expr {
	open := _advance(ctx) // consume {

	if _at(ctx, .RBRACE) {
		_advance(ctx)
		d := new(Dict_Expr, ctx.allocator)
		d.loc = open.loc
		return d
	}

	// Check for **expr (dict unpacking)
	if _at(ctx, .DOUBLE_STAR) {
		return _parse_dict_rest(ctx, open.loc, nil, nil)
	}

	first := parse_expr(ctx)

	if _at(ctx, .COLON) {
		// Dict
		_advance(ctx) // consume :
		val := parse_expr(ctx)

		if _at(ctx, .KW_FOR) {
			// Dict comprehension
			comp := _parse_dict_comp(ctx, first, val, open.loc)
			_expect(ctx, .RBRACE)
			return comp
		}

		return _parse_dict_rest(ctx, open.loc, first, val)
	}

	if _at(ctx, .KW_FOR) {
		// Set comprehension
		comp := _parse_set_comp(ctx, first, open.loc)
		_expect(ctx, .RBRACE)
		return comp
	}

	// Set literal
	elts := make([dynamic]Expr, 0, 4, ctx.allocator)
	append(&elts, first)
	for _at(ctx, .COMMA) {
		_advance(ctx)
		if _at(ctx, .RBRACE) { break }
		e := parse_expr(ctx)
		if e != nil { append(&elts, e) }
	}
	_expect(ctx, .RBRACE)
	s := new(Set_Expr, ctx.allocator)
	s.loc = open.loc
	s.elts = elts[:]
	return s
}

_parse_dict_rest :: proc(ctx: ^Parser_Context, loc: Src_Loc, first_key: Expr, first_val: Expr) -> Expr {
	keys := make([dynamic]Expr, 0, 4, ctx.allocator)
	vals := make([dynamic]Expr, 0, 4, ctx.allocator)

	if first_key != nil {
		append(&keys, first_key)
		append(&vals, first_val)
	}

	for _at(ctx, .COMMA) || _at(ctx, .DOUBLE_STAR) {
		if _at(ctx, .COMMA) { _advance(ctx) }
		if _at(ctx, .RBRACE) { break }

		if _at(ctx, .DOUBLE_STAR) {
			_advance(ctx)
			append(&keys, Expr(nil))
			append(&vals, parse_expr(ctx))
		} else {
			k := parse_expr(ctx)
			_expect(ctx, .COLON)
			v := parse_expr(ctx)
			append(&keys, k)
			append(&vals, v)
		}
	}
	_expect(ctx, .RBRACE)

	d := new(Dict_Expr, ctx.allocator)
	d.loc = loc
	d.keys = keys[:]
	d.values = vals[:]
	return d
}

_parse_unary :: proc(ctx: ^Parser_Context) -> Expr {
	tok := _advance(ctx)
	operand := parse_expr(ctx, PREC_UNARY)

	op: Unary_Op
	#partial switch tok.kind {
	case .MINUS: op = .USub
	case .PLUS:  op = .UAdd
	case .TILDE: op = .Invert
	case: op = .UAdd
	}

	u := new(Unary_Op_Expr, ctx.allocator)
	u.loc = tok.loc
	u.op = op
	u.operand = operand
	return u
}

_parse_not :: proc(ctx: ^Parser_Context) -> Expr {
	tok := _advance(ctx) // consume 'not'
	operand := parse_expr(ctx, PREC_NOT)
	u := new(Unary_Op_Expr, ctx.allocator)
	u.loc = tok.loc
	u.op = .Not
	u.operand = operand
	return u
}

_parse_lambda :: proc(ctx: ^Parser_Context) -> Expr {
	tok := _advance(ctx) // consume 'lambda'

	args := _parse_lambda_params(ctx)
	_expect(ctx, .COLON)
	body := parse_expr(ctx, PREC_LAMBDA)

	l := new(Lambda_Expr, ctx.allocator)
	l.loc = tok.loc
	l.args = args
	l.body = body
	return l
}

_parse_lambda_params :: proc(ctx: ^Parser_Context) -> Arguments {
	args: Arguments
	params := make([dynamic]Arg, 0, 4, ctx.allocator)

	for !_at(ctx, .COLON) && !_at(ctx, .EOF) {
		if _at(ctx, .COMMA) { _advance(ctx); continue }
		if _at(ctx, .STAR) {
			_advance(ctx)
			// *args or bare *
			if _at(ctx, .NAME) {
				tok := _advance(ctx)
				va := new(Arg, ctx.allocator)
				va.loc = tok.loc
				va.arg = tok.text
				args.vararg = va
			}
			continue
		}
		if _at(ctx, .DOUBLE_STAR) {
			_advance(ctx)
			if _at(ctx, .NAME) {
				tok := _advance(ctx)
				kw := new(Arg, ctx.allocator)
				kw.loc = tok.loc
				kw.arg = tok.text
				args.kwarg = kw
			}
			continue
		}
		if _at_any(ctx, .NAME, .KW_MATCH, .KW_CASE, .KW_TYPE) {
			tok := _advance(ctx)
			param := Arg{loc = tok.loc, arg = tok.text}
			// Check for default value
			if _at(ctx, .ASSIGN) {
				_advance(ctx)
				param.annotation = nil // lambda params don't have annotations
			}
			append(&params, param)
		} else {
			break
		}
	}
	args.args = params[:]
	return args
}

_parse_await :: proc(ctx: ^Parser_Context) -> Expr {
	tok := _advance(ctx) // consume 'await'
	value := parse_expr(ctx, PREC_AWAIT)
	a := new(Await_Expr, ctx.allocator)
	a.loc = tok.loc
	a.value = value
	return a
}

_parse_yield :: proc(ctx: ^Parser_Context) -> Expr {
	tok := _advance(ctx) // consume 'yield'

	if _at(ctx, .KW_FROM) {
		_advance(ctx) // consume 'from'
		value := parse_expr(ctx)
		yf := new(Yield_From_Expr, ctx.allocator)
		yf.loc = tok.loc
		yf.value = value
		return yf
	}

	if _at_any(ctx, .NEWLINE, .RPAREN, .RBRACKET, .RBRACE, .EOF, .SEMICOLON) {
		y := new(Yield_Expr, ctx.allocator)
		y.loc = tok.loc
		return y
	}

	value := parse_expr_list(ctx)
	y := new(Yield_Expr, ctx.allocator)
	y.loc = tok.loc
	y.value = value
	return y
}

_parse_starred :: proc(ctx: ^Parser_Context) -> Expr {
	tok := _advance(ctx) // consume *
	value := parse_expr(ctx, PREC_MUL)
	s := new(Starred_Expr, ctx.allocator)
	s.loc = tok.loc
	s.value = value
	s.ctx = .Load
	return s
}

// ==================== Infix Implementations ====================

_parse_binop :: proc(ctx: ^Parser_Context, left: Expr, prec: int) -> Expr {
	tok := _advance(ctx)
	right := parse_expr(ctx, prec)

	op: Binary_Op
	#partial switch tok.kind {
	case .PLUS:         op = .Add
	case .MINUS:        op = .Sub
	case .STAR:         op = .Mult
	case .SLASH:        op = .Div
	case .DOUBLE_SLASH: op = .Floor_Div
	case .PERCENT:      op = .Mod
	case .AT:           op = .Mat_Mult
	case .PIPE:         op = .Bit_Or
	case .CARET:        op = .Bit_Xor
	case .AMPERSAND:    op = .Bit_And
	case .LSHIFT:       op = .LShift
	case .RSHIFT:       op = .RShift
	case:               op = .Add
	}

	b := new(Bin_Op_Expr, ctx.allocator)
	b.loc = _expr_loc(left)
	b.left = left
	b.op = op
	b.right = right
	return b
}

_parse_binop_right :: proc(ctx: ^Parser_Context, left: Expr, prec: int) -> Expr {
	tok := _advance(ctx)
	right := parse_expr(ctx, prec - 1) // right-associative

	op: Binary_Op
	#partial switch tok.kind {
	case .DOUBLE_STAR: op = .Pow
	case:              op = .Pow
	}

	b := new(Bin_Op_Expr, ctx.allocator)
	b.loc = _expr_loc(left)
	b.left = left
	b.op = op
	b.right = right
	return b
}

_parse_boolop :: proc(ctx: ^Parser_Context, left: Expr, op: Bool_Op_Kind) -> Expr {
	_advance(ctx) // consume and/or
	right := parse_expr(ctx, PREC_AND if op == .And else PREC_OR)

	// Collect chained: a and b and c → BoolOp(and, [a, b, c])
	values := make([dynamic]Expr, 0, 3, ctx.allocator)
	// Flatten left if same op
	#partial switch le in left {
	case ^Bool_Op_Expr:
		if le.op == op {
			for v in le.values { append(&values, v) }
		} else {
			append(&values, left)
		}
	case:
		append(&values, left)
	}
	append(&values, right)

	b := new(Bool_Op_Expr, ctx.allocator)
	b.loc = _expr_loc(left)
	b.op = op
	b.values = values[:]
	return b
}

_parse_comparison :: proc(ctx: ^Parser_Context, left: Expr) -> Expr {
	ops := make([dynamic]Cmp_Op, 0, 2, ctx.allocator)
	comparators := make([dynamic]Expr, 0, 2, ctx.allocator)

	for {
		tok := _peek(ctx)
		cmp_op: Cmp_Op
		found := true

		#partial switch tok.kind {
		case .LT:     _advance(ctx); cmp_op = .Lt
		case .GT:     _advance(ctx); cmp_op = .Gt
		case .LE:     _advance(ctx); cmp_op = .Lt_E
		case .GE:     _advance(ctx); cmp_op = .Gt_E
		case .EQ_EQ:  _advance(ctx); cmp_op = .Eq
		case .NOT_EQ: _advance(ctx); cmp_op = .Not_Eq
		case .KW_IN:  _advance(ctx); cmp_op = .In
		case .KW_IS:
			_advance(ctx)
			if _at(ctx, .KW_NOT) {
				_advance(ctx)
				cmp_op = .Is_Not
			} else {
				cmp_op = .Is
			}
		case .KW_NOT:
			_advance(ctx)
			if _at(ctx, .KW_IN) {
				_advance(ctx)
				cmp_op = .Not_In
			} else {
				// 'not' is not a comparison — put it back
				ctx.pos -= 1
				found = false
			}
		case:
			found = false
		}

		if !found { break }

		append(&ops, cmp_op)
		right := parse_expr(ctx, PREC_CMP)
		append(&comparators, right)
	}

	c := new(Compare_Expr, ctx.allocator)
	c.loc = _expr_loc(left)
	c.left = left
	c.ops = ops[:]
	c.comparators = comparators[:]
	return c
}

_parse_ternary :: proc(ctx: ^Parser_Context, body: Expr) -> Expr {
	_advance(ctx) // consume 'if'
	test := parse_expr(ctx, PREC_TERNARY)
	_expect(ctx, .KW_ELSE)
	orelse := parse_expr(ctx, PREC_TERNARY)

	ie := new(If_Expr, ctx.allocator)
	ie.loc = _expr_loc(body)
	ie.test = test
	ie.body = body
	ie.orelse = orelse
	return ie
}

_parse_walrus :: proc(ctx: ^Parser_Context, left: Expr) -> Expr {
	_advance(ctx) // consume :=
	value := parse_expr(ctx)

	ne := new(Named_Expr, ctx.allocator)
	ne.loc = _expr_loc(left)
	ne.target = left
	ne.value = value
	return ne
}

_parse_call :: proc(ctx: ^Parser_Context, func_expr: Expr) -> Expr {
	_advance(ctx) // consume (

	args := make([dynamic]Expr, 0, 4, ctx.allocator)
	keywords := make([dynamic]Keyword, 0, 2, ctx.allocator)

	for !_at(ctx, .RPAREN) && !_at(ctx, .EOF) {
		if len(args) > 0 || len(keywords) > 0 {
			if !_at(ctx, .COMMA) { break }
			_advance(ctx) // consume ,
			if _at(ctx, .RPAREN) { break }
		}

		// **kwargs
		if _at(ctx, .DOUBLE_STAR) {
			_advance(ctx)
			val := parse_expr(ctx)
			append(&keywords, Keyword{arg = "", value = val})
			continue
		}

		// Check for keyword argument: name=value
		if (_at_any(ctx, .NAME, .KW_MATCH, .KW_CASE, .KW_TYPE)) && ctx.pos + 1 < len(ctx.tokens) && ctx.tokens[ctx.pos + 1].kind == .ASSIGN {
			name_tok := _advance(ctx)
			_advance(ctx) // consume =
			val := parse_expr(ctx)
			append(&keywords, Keyword{arg = name_tok.text, value = val, loc = name_tok.loc})
			continue
		}

		// *args
		if _at(ctx, .STAR) {
			_advance(ctx)
			val := parse_expr(ctx)
			s := new(Starred_Expr, ctx.allocator)
			s.loc = _expr_loc(val)
			s.value = val
			s.ctx = .Load
			append(&args, Expr(s))
			continue
		}

		arg := parse_expr(ctx)
		if arg != nil { append(&args, arg) }
	}

	_expect(ctx, .RPAREN)

	call := new(Call_Expr, ctx.allocator)
	call.loc = _expr_loc(func_expr)
	call.func = func_expr
	call.args = args[:]
	call.keywords = keywords[:]
	return call
}

_parse_subscript :: proc(ctx: ^Parser_Context, value: Expr) -> Expr {
	_advance(ctx) // consume [

	// Parse slice or index
	sl := _parse_slice_or_index(ctx)

	_expect(ctx, .RBRACKET)

	sub := new(Subscript_Expr, ctx.allocator)
	sub.loc = _expr_loc(value)
	sub.value = value
	sub.slice = sl
	sub.ctx = .Load
	return sub
}

_parse_slice_or_index :: proc(ctx: ^Parser_Context) -> Expr {
	// Check for : (slice with no lower)
	if _at(ctx, .COLON) {
		return _parse_slice(ctx, nil)
	}

	lower := parse_expr(ctx)

	if _at(ctx, .COLON) {
		return _parse_slice(ctx, lower)
	}

	// Tuple index: x[a, b]
	if _at(ctx, .COMMA) {
		elts := make([dynamic]Expr, 0, 3, ctx.allocator)
		append(&elts, lower)
		for _at(ctx, .COMMA) {
			_advance(ctx)
			if _at(ctx, .RBRACKET) { break }
			e := parse_expr(ctx)
			if e != nil { append(&elts, e) }
		}
		t := new(Tuple_Expr, ctx.allocator)
		t.loc = _expr_loc(lower)
		t.elts = elts[:]
		t.ctx = .Load
		return t
	}

	return lower
}

_parse_slice :: proc(ctx: ^Parser_Context, lower: Expr) -> Expr {
	_advance(ctx) // consume :

	upper: Expr
	if !_at_any(ctx, .COLON, .RBRACKET, .COMMA) {
		upper = parse_expr(ctx)
	}

	step: Expr
	if _at(ctx, .COLON) {
		_advance(ctx)
		if !_at_any(ctx, .RBRACKET, .COMMA) {
			step = parse_expr(ctx)
		}
	}

	s := new(Slice_Expr, ctx.allocator)
	s.loc = _expr_loc(lower) if lower != nil else _peek(ctx).loc
	s.lower = lower
	s.upper = upper
	s.step = step
	return s
}

_parse_attribute :: proc(ctx: ^Parser_Context, value: Expr) -> Expr {
	_advance(ctx) // consume .
	attr_tok := _advance(ctx)

	a := new(Attribute_Expr, ctx.allocator)
	a.loc = _expr_loc(value)
	a.value = value
	a.attr = attr_tok.text
	a.ctx = .Load
	return a
}

// ==================== Comprehensions ====================

_parse_comprehension_tail :: proc(ctx: ^Parser_Context, elt: Expr, loc: Src_Loc) -> Expr {
	generators := _parse_generators(ctx)
	g := new(Generator_Expr, ctx.allocator)
	g.loc = loc
	g.elt = elt
	g.generators = generators
	return g
}

_parse_list_comp :: proc(ctx: ^Parser_Context, elt: Expr, loc: Src_Loc) -> Expr {
	generators := _parse_generators(ctx)
	lc := new(List_Comp, ctx.allocator)
	lc.loc = loc
	lc.elt = elt
	lc.generators = generators
	return lc
}

_parse_set_comp :: proc(ctx: ^Parser_Context, elt: Expr, loc: Src_Loc) -> Expr {
	generators := _parse_generators(ctx)
	sc := new(Set_Comp, ctx.allocator)
	sc.loc = loc
	sc.elt = elt
	sc.generators = generators
	return sc
}

_parse_dict_comp :: proc(ctx: ^Parser_Context, key: Expr, value: Expr, loc: Src_Loc) -> Expr {
	generators := _parse_generators(ctx)
	dc := new(Dict_Comp, ctx.allocator)
	dc.loc = loc
	dc.key = key
	dc.value = value
	dc.generators = generators
	return dc
}

_parse_generators :: proc(ctx: ^Parser_Context) -> []Comprehension {
	gens := make([dynamic]Comprehension, 0, 2, ctx.allocator)

	for _at(ctx, .KW_FOR) || _at(ctx, .KW_ASYNC) {
		is_async := false
		if _at(ctx, .KW_ASYNC) {
			_advance(ctx)
			is_async = true
		}
		_expect(ctx, .KW_FOR)

		target := _parse_target_list(ctx) // don't consume 'in'
		_expect(ctx, .KW_IN)
		iter := parse_expr(ctx, PREC_TERNARY) // don't consume 'if'

		ifs := make([dynamic]Expr, 0, 2, ctx.allocator)
		for _at(ctx, .KW_IF) {
			_advance(ctx)
			cond := parse_expr(ctx, PREC_TERNARY)
			append(&ifs, cond)
		}

		append(&gens, Comprehension{
			target   = target,
			iter     = iter,
			ifs      = ifs[:],
			is_async = is_async,
		})
	}
	return gens[:]
}

// ==================== Helpers ====================

_expr_loc :: proc(e: Expr) -> Src_Loc {
	if e == nil { return {} }
	// Extract loc from any expr variant
	#partial switch n in e {
	case ^Name_Expr:      return n.loc
	case ^Constant_Expr:  return n.loc
	case ^Bin_Op_Expr:    return n.loc
	case ^Unary_Op_Expr:  return n.loc
	case ^Bool_Op_Expr:   return n.loc
	case ^Compare_Expr:   return n.loc
	case ^Call_Expr:      return n.loc
	case ^Attribute_Expr: return n.loc
	case ^Subscript_Expr: return n.loc
	case ^If_Expr:        return n.loc
	case ^Lambda_Expr:    return n.loc
	case ^Tuple_Expr:     return n.loc
	case ^List_Expr:      return n.loc
	case ^Dict_Expr:      return n.loc
	case ^Set_Expr:       return n.loc
	case ^Starred_Expr:   return n.loc
	case ^Named_Expr:     return n.loc
	case ^Joined_Str:     return n.loc
	case ^Await_Expr:     return n.loc
	case ^Yield_Expr:     return n.loc
	case ^Yield_From_Expr: return n.loc
	case ^List_Comp:      return n.loc
	case ^Set_Comp:       return n.loc
	case ^Dict_Comp:      return n.loc
	case ^Generator_Expr: return n.loc
	case ^Slice_Expr:     return n.loc
	case ^Formatted_Value: return n.loc
	}
	return {}
}

_make_const_bool :: proc(ctx: ^Parser_Context, val: bool, loc: Src_Loc) -> Expr {
	c := new(Constant_Expr, ctx.allocator)
	c.loc = loc
	c.value = val
	return c
}

_make_const_none :: proc(ctx: ^Parser_Context, loc: Src_Loc) -> Expr {
	c := new(Constant_Expr, ctx.allocator)
	c.loc = loc
	c.value = Const_None{}
	return c
}

// Extract string content from a quoted string token (strip quotes + prefix)
_extract_string_content :: proc(text: string, allocator: mem.Allocator) -> string {
	s := text
	// Skip prefix chars
	for len(s) > 0 && s[0] != '\'' && s[0] != '"' {
		s = s[1:]
	}
	if len(s) == 0 { return "" }

	quote := s[0]
	// Triple-quoted
	if len(s) >= 6 && s[1] == quote && s[2] == quote {
		return strings.clone(s[3:len(s)-3], allocator)
	}
	// Single-quoted
	if len(s) >= 2 {
		return strings.clone(s[1:len(s)-1], allocator)
	}
	return ""
}
