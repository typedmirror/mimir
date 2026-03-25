package core

// Shared AST walker — single source of truth for expression/statement traversal.
// Handles ALL Stmt and Expr variants. Modules use this instead of per-module walkers.
//
// Usage:
//   visitor := AST_Visitor{ visit_expr = my_callback, ctx = rawptr(&my_context) }
//   walk_all_stmts(&visitor, module.body)

import parser "mimir:parser"

AST_Visitor :: struct {
	visit_expr: proc(expr: parser.Expr, ctx: rawptr),
	visit_stmt: proc(stmt: parser.Stmt, ctx: rawptr),  // called BEFORE body recursion
	leave_stmt: proc(stmt: parser.Stmt, ctx: rawptr),  // called AFTER body recursion
	ctx:        rawptr,
}

// Walk all statements recursively, visiting every expression encountered.
walk_all_stmts :: proc(v: ^AST_Visitor, stmts: []parser.Stmt) {
	single := [1]AST_Visitor{v^}
	walk_all_stmts_multi(single[:], stmts)
}

// Walk all statements with multiple visitors in a single traversal.
// Eliminates the need for N separate walk_all_stmts calls when N passes
// each need to see the same AST.
walk_all_stmts_multi :: proc(visitors: []AST_Visitor, stmts: []parser.Stmt) {
	for stmt in stmts {
		_walk_stmt_multi(visitors, stmt)
	}
}

@(private = "file")
_walk_stmt_multi :: proc(visitors: []AST_Visitor, stmt: parser.Stmt) {
	for &v in visitors {
		if v.visit_stmt != nil { v.visit_stmt(stmt, v.ctx) }
	}
	// Recurse into sub-statements and expressions using a dispatch visitor
	// that forwards to all registered visitors
	#partial switch s in stmt {
	case ^parser.Expr_Stmt:
		_walk_expr_multi(visitors, s.value)
	case ^parser.Assign:
		_walk_expr_multi(visitors, s.value)
		for t in s.targets { _walk_expr_multi(visitors, t) }
	case ^parser.Ann_Assign:
		_walk_expr_multi(visitors, s.annotation)
		if s.value != nil { _walk_expr_multi(visitors, s.value) }
	case ^parser.Aug_Assign:
		_walk_expr_multi(visitors, s.target)
		_walk_expr_multi(visitors, s.value)
	case ^parser.Return_Stmt:
		if s.value != nil { _walk_expr_multi(visitors, s.value) }
	case ^parser.Assert_Stmt:
		_walk_expr_multi(visitors, s.test)
		if s.msg != nil { _walk_expr_multi(visitors, s.msg) }
	case ^parser.Raise_Stmt:
		if s.exc != nil { _walk_expr_multi(visitors, s.exc) }
		if s.cause != nil { _walk_expr_multi(visitors, s.cause) }
	case ^parser.Delete_Stmt:
		for t in s.targets { _walk_expr_multi(visitors, t) }
	case ^parser.Func_Def:
		for d in s.decorator_list { _walk_expr_multi(visitors, d) }
		_walk_func_args_multi(visitors, &s.args)
		if s.returns != nil { _walk_expr_multi(visitors, s.returns) }
		walk_all_stmts_multi(visitors, s.body)
	case ^parser.Async_Func_Def:
		for d in s.decorator_list { _walk_expr_multi(visitors, d) }
		_walk_func_args_multi(visitors, &s.args)
		if s.returns != nil { _walk_expr_multi(visitors, s.returns) }
		walk_all_stmts_multi(visitors, s.body)
	case ^parser.Class_Def:
		for d in s.decorator_list { _walk_expr_multi(visitors, d) }
		for b in s.bases { _walk_expr_multi(visitors, b) }
		for kw in s.keywords { _walk_expr_multi(visitors, kw.value) }
		walk_all_stmts_multi(visitors, s.body)
	case ^parser.If_Stmt:
		_walk_expr_multi(visitors, s.test)
		walk_all_stmts_multi(visitors, s.body)
		walk_all_stmts_multi(visitors, s.orelse)
	case ^parser.For_Stmt:
		_walk_expr_multi(visitors, s.target)
		_walk_expr_multi(visitors, s.iter)
		walk_all_stmts_multi(visitors, s.body)
		walk_all_stmts_multi(visitors, s.orelse)
	case ^parser.Async_For:
		_walk_expr_multi(visitors, s.target)
		_walk_expr_multi(visitors, s.iter)
		walk_all_stmts_multi(visitors, s.body)
		walk_all_stmts_multi(visitors, s.orelse)
	case ^parser.While_Stmt:
		_walk_expr_multi(visitors, s.test)
		walk_all_stmts_multi(visitors, s.body)
		walk_all_stmts_multi(visitors, s.orelse)
	case ^parser.With_Stmt:
		for item in s.items {
			_walk_expr_multi(visitors, item.context_expr)
			if item.optional_vars != nil { _walk_expr_multi(visitors, item.optional_vars) }
		}
		walk_all_stmts_multi(visitors, s.body)
	case ^parser.Async_With:
		for item in s.items {
			_walk_expr_multi(visitors, item.context_expr)
			if item.optional_vars != nil { _walk_expr_multi(visitors, item.optional_vars) }
		}
		walk_all_stmts_multi(visitors, s.body)
	case ^parser.Try_Stmt:
		walk_all_stmts_multi(visitors, s.body)
		for h in s.handlers {
			if h.type != nil { _walk_expr_multi(visitors, h.type) }
			walk_all_stmts_multi(visitors, h.body)
		}
		walk_all_stmts_multi(visitors, s.orelse)
		walk_all_stmts_multi(visitors, s.finalbody)
	case ^parser.Try_Star:
		walk_all_stmts_multi(visitors, s.body)
		for h in s.handlers {
			if h.type != nil { _walk_expr_multi(visitors, h.type) }
			walk_all_stmts_multi(visitors, h.body)
		}
		walk_all_stmts_multi(visitors, s.orelse)
		walk_all_stmts_multi(visitors, s.finalbody)
	case ^parser.Match_Stmt:
		_walk_expr_multi(visitors, s.subject)
		for c in s.cases {
			_walk_pattern_multi(visitors, c.pattern)
			if c.guard != nil { _walk_expr_multi(visitors, c.guard) }
			walk_all_stmts_multi(visitors, c.body)
		}
	case ^parser.Type_Alias_Stmt:
		if s.value != nil { _walk_expr_multi(visitors, s.value) }
	case ^parser.Pass_Stmt:
	case ^parser.Break_Stmt:
	case ^parser.Continue_Stmt:
	case ^parser.Global_Stmt:
	case ^parser.Nonlocal_Stmt:
	case ^parser.Import_Stmt:
	case ^parser.Import_From:
	}
	for &v in visitors {
		if v.leave_stmt != nil { v.leave_stmt(stmt, v.ctx) }
	}
}

@(private = "file")
_walk_expr_multi :: proc(visitors: []AST_Visitor, expr: parser.Expr) {
	if expr == nil { return }
	for &v in visitors {
		if v.visit_expr != nil { v.visit_expr(expr, v.ctx) }
	}
	#partial switch e in expr {
	case ^parser.Call_Expr:
		_walk_expr_multi(visitors, e.func)
		for a in e.args { _walk_expr_multi(visitors, a) }
		for kw in e.keywords { _walk_expr_multi(visitors, kw.value) }
	case ^parser.Bin_Op_Expr:
		_walk_expr_multi(visitors, e.left)
		_walk_expr_multi(visitors, e.right)
	case ^parser.Unary_Op_Expr:
		_walk_expr_multi(visitors, e.operand)
	case ^parser.Bool_Op_Expr:
		for val in e.values { _walk_expr_multi(visitors, val) }
	case ^parser.Compare_Expr:
		_walk_expr_multi(visitors, e.left)
		for c in e.comparators { _walk_expr_multi(visitors, c) }
	case ^parser.If_Expr:
		_walk_expr_multi(visitors, e.test)
		_walk_expr_multi(visitors, e.body)
		_walk_expr_multi(visitors, e.orelse)
	case ^parser.Lambda_Expr:
		_walk_expr_multi(visitors, e.body)
	case ^parser.Dict_Expr:
		for k in e.keys { _walk_expr_multi(visitors, k) }
		for val in e.values { _walk_expr_multi(visitors, val) }
	case ^parser.Set_Expr:
		for elt in e.elts { _walk_expr_multi(visitors, elt) }
	case ^parser.List_Expr:
		for elt in e.elts { _walk_expr_multi(visitors, elt) }
	case ^parser.Tuple_Expr:
		for elt in e.elts { _walk_expr_multi(visitors, elt) }
	case ^parser.Joined_Str:
		for val in e.values { _walk_expr_multi(visitors, val) }
	case ^parser.Formatted_Value:
		_walk_expr_multi(visitors, e.value)
	case ^parser.Attribute_Expr:
		_walk_expr_multi(visitors, e.value)
	case ^parser.Subscript_Expr:
		_walk_expr_multi(visitors, e.value)
		_walk_expr_multi(visitors, e.slice)
	case ^parser.Starred_Expr:
		_walk_expr_multi(visitors, e.value)
	case ^parser.Named_Expr:
		_walk_expr_multi(visitors, e.target)
		_walk_expr_multi(visitors, e.value)
	case ^parser.Await_Expr:
		_walk_expr_multi(visitors, e.value)
	case ^parser.Yield_Expr:
		if e.value != nil { _walk_expr_multi(visitors, e.value) }
	case ^parser.Yield_From_Expr:
		_walk_expr_multi(visitors, e.value)
	case ^parser.Slice_Expr:
		if e.lower != nil { _walk_expr_multi(visitors, e.lower) }
		if e.upper != nil { _walk_expr_multi(visitors, e.upper) }
		if e.step != nil { _walk_expr_multi(visitors, e.step) }
	case ^parser.List_Comp:
		_walk_expr_multi(visitors, e.elt)
		for gen in e.generators {
			_walk_expr_multi(visitors, gen.iter)
			if gen.target != nil { _walk_expr_multi(visitors, gen.target) }
			for cond in gen.ifs { _walk_expr_multi(visitors, cond) }
		}
	case ^parser.Set_Comp:
		_walk_expr_multi(visitors, e.elt)
		for gen in e.generators {
			_walk_expr_multi(visitors, gen.iter)
			if gen.target != nil { _walk_expr_multi(visitors, gen.target) }
			for cond in gen.ifs { _walk_expr_multi(visitors, cond) }
		}
	case ^parser.Dict_Comp:
		_walk_expr_multi(visitors, e.key)
		_walk_expr_multi(visitors, e.value)
		for gen in e.generators {
			_walk_expr_multi(visitors, gen.iter)
			if gen.target != nil { _walk_expr_multi(visitors, gen.target) }
			for cond in gen.ifs { _walk_expr_multi(visitors, cond) }
		}
	case ^parser.Generator_Expr:
		_walk_expr_multi(visitors, e.elt)
		for gen in e.generators {
			_walk_expr_multi(visitors, gen.iter)
			if gen.target != nil { _walk_expr_multi(visitors, gen.target) }
			for cond in gen.ifs { _walk_expr_multi(visitors, cond) }
		}
	case ^parser.Name_Expr:
	case ^parser.Constant_Expr:
	}
}

@(private = "file")
_walk_func_args_multi :: proc(visitors: []AST_Visitor, args: ^parser.Arguments) {
	if args == nil { return }
	for &a in args.posonlyargs { if a.annotation != nil { _walk_expr_multi(visitors, a.annotation) } }
	for &a in args.args { if a.annotation != nil { _walk_expr_multi(visitors, a.annotation) } }
	for &a in args.kwonlyargs { if a.annotation != nil { _walk_expr_multi(visitors, a.annotation) } }
	if args.vararg != nil && args.vararg.annotation != nil { _walk_expr_multi(visitors, args.vararg.annotation) }
	if args.kwarg != nil && args.kwarg.annotation != nil { _walk_expr_multi(visitors, args.kwarg.annotation) }
	for d in args.defaults { if d != nil { _walk_expr_multi(visitors, d) } }
	for d in args.kw_defaults { if d != nil { _walk_expr_multi(visitors, d) } }
}

@(private = "file")
_walk_pattern_multi :: proc(visitors: []AST_Visitor, pattern: parser.Pattern) {
	#partial switch p in pattern {
	case ^parser.Match_Value:
		_walk_expr_multi(visitors, p.value)
	case ^parser.Match_Sequence:
		for sub in p.patterns { _walk_pattern_multi(visitors, sub) }
	case ^parser.Match_Mapping:
		for k in p.keys { _walk_expr_multi(visitors, k) }
		for sub in p.patterns { _walk_pattern_multi(visitors, sub) }
	case ^parser.Match_Class:
		_walk_expr_multi(visitors, p.cls)
		for sub in p.patterns { _walk_pattern_multi(visitors, sub) }
		for sub in p.kwd_patterns { _walk_pattern_multi(visitors, sub) }
	case ^parser.Match_As:
		_walk_pattern_multi(visitors, p.pattern)
	case ^parser.Match_Or:
		for sub in p.patterns { _walk_pattern_multi(visitors, sub) }
	}
}

walk_stmt :: proc(v: ^AST_Visitor, stmt: parser.Stmt) {
	if v.visit_stmt != nil { v.visit_stmt(stmt, v.ctx) }
	#partial switch s in stmt {
	case ^parser.Expr_Stmt:
		walk_expr(v, s.value)
	case ^parser.Assign:
		walk_expr(v, s.value)
		for t in s.targets { walk_expr(v, t) }
	case ^parser.Ann_Assign:
		walk_expr(v, s.annotation)
		if s.value != nil { walk_expr(v, s.value) }
	case ^parser.Aug_Assign:
		walk_expr(v, s.target)
		walk_expr(v, s.value)
	case ^parser.Return_Stmt:
		if s.value != nil { walk_expr(v, s.value) }
	case ^parser.Assert_Stmt:
		walk_expr(v, s.test)
		if s.msg != nil { walk_expr(v, s.msg) }
	case ^parser.Raise_Stmt:
		if s.exc != nil { walk_expr(v, s.exc) }
		if s.cause != nil { walk_expr(v, s.cause) }
	case ^parser.Delete_Stmt:
		for t in s.targets { walk_expr(v, t) }

	// Compound statements — recurse into bodies
	case ^parser.Func_Def:
		for d in s.decorator_list { walk_expr(v, d) }
		walk_func_args(v, &s.args)
		if s.returns != nil { walk_expr(v, s.returns) }
		walk_all_stmts(v, s.body)
	case ^parser.Async_Func_Def:
		for d in s.decorator_list { walk_expr(v, d) }
		walk_func_args(v, &s.args)
		if s.returns != nil { walk_expr(v, s.returns) }
		walk_all_stmts(v, s.body)
	case ^parser.Class_Def:
		for d in s.decorator_list { walk_expr(v, d) }
		for b in s.bases { walk_expr(v, b) }
		for kw in s.keywords { walk_expr(v, kw.value) }
		walk_all_stmts(v, s.body)
	case ^parser.If_Stmt:
		walk_expr(v, s.test)
		walk_all_stmts(v, s.body)
		walk_all_stmts(v, s.orelse)
	case ^parser.For_Stmt:
		walk_expr(v, s.target)
		walk_expr(v, s.iter)
		walk_all_stmts(v, s.body)
		walk_all_stmts(v, s.orelse)
	case ^parser.Async_For:
		walk_expr(v, s.target)
		walk_expr(v, s.iter)
		walk_all_stmts(v, s.body)
		walk_all_stmts(v, s.orelse)
	case ^parser.While_Stmt:
		walk_expr(v, s.test)
		walk_all_stmts(v, s.body)
		walk_all_stmts(v, s.orelse)
	case ^parser.With_Stmt:
		for item in s.items {
			walk_expr(v, item.context_expr)
			if item.optional_vars != nil { walk_expr(v, item.optional_vars) }
		}
		walk_all_stmts(v, s.body)
	case ^parser.Async_With:
		for item in s.items {
			walk_expr(v, item.context_expr)
			if item.optional_vars != nil { walk_expr(v, item.optional_vars) }
		}
		walk_all_stmts(v, s.body)
	case ^parser.Try_Stmt:
		walk_all_stmts(v, s.body)
		for h in s.handlers {
			if h.type != nil { walk_expr(v, h.type) }
			walk_all_stmts(v, h.body)
		}
		walk_all_stmts(v, s.orelse)
		walk_all_stmts(v, s.finalbody)
	case ^parser.Try_Star:
		walk_all_stmts(v, s.body)
		for h in s.handlers {
			if h.type != nil { walk_expr(v, h.type) }
			walk_all_stmts(v, h.body)
		}
		walk_all_stmts(v, s.orelse)
		walk_all_stmts(v, s.finalbody)
	case ^parser.Match_Stmt:
		walk_expr(v, s.subject)
		for c in s.cases {
			walk_pattern(v, c.pattern)
			if c.guard != nil { walk_expr(v, c.guard) }
			walk_all_stmts(v, c.body)
		}
	case ^parser.Type_Alias_Stmt:
		if s.value != nil { walk_expr(v, s.value) }

	// No expressions to visit
	case ^parser.Pass_Stmt:
	case ^parser.Break_Stmt:
	case ^parser.Continue_Stmt:
	case ^parser.Global_Stmt:
	case ^parser.Nonlocal_Stmt:
	case ^parser.Import_Stmt:
	case ^parser.Import_From:
	}
	if v.leave_stmt != nil { v.leave_stmt(stmt, v.ctx) }
}

// Walk an expression tree recursively, calling visit_expr on every node.
walk_expr :: proc(v: ^AST_Visitor, expr: parser.Expr) {
	if expr == nil { return }
	if v.visit_expr != nil { v.visit_expr(expr, v.ctx) }

	#partial switch e in expr {
	case ^parser.Call_Expr:
		walk_expr(v, e.func)
		for a in e.args { walk_expr(v, a) }
		for kw in e.keywords { walk_expr(v, kw.value) }
	case ^parser.Bin_Op_Expr:
		walk_expr(v, e.left)
		walk_expr(v, e.right)
	case ^parser.Unary_Op_Expr:
		walk_expr(v, e.operand)
	case ^parser.Bool_Op_Expr:
		for val in e.values { walk_expr(v, val) }
	case ^parser.Compare_Expr:
		walk_expr(v, e.left)
		for c in e.comparators { walk_expr(v, c) }
	case ^parser.If_Expr:
		walk_expr(v, e.test)
		walk_expr(v, e.body)
		walk_expr(v, e.orelse)
	case ^parser.Lambda_Expr:
		walk_expr(v, e.body)
	case ^parser.Dict_Expr:
		for k in e.keys { walk_expr(v, k) }
		for val in e.values { walk_expr(v, val) }
	case ^parser.Set_Expr:
		for elt in e.elts { walk_expr(v, elt) }
	case ^parser.List_Expr:
		for elt in e.elts { walk_expr(v, elt) }
	case ^parser.Tuple_Expr:
		for elt in e.elts { walk_expr(v, elt) }
	case ^parser.Joined_Str:
		for val in e.values { walk_expr(v, val) }
	case ^parser.Formatted_Value:
		walk_expr(v, e.value)
	case ^parser.Attribute_Expr:
		walk_expr(v, e.value)
	case ^parser.Subscript_Expr:
		walk_expr(v, e.value)
		walk_expr(v, e.slice)
	case ^parser.Starred_Expr:
		walk_expr(v, e.value)
	case ^parser.Named_Expr:
		walk_expr(v, e.target)
		walk_expr(v, e.value)
	case ^parser.Await_Expr:
		walk_expr(v, e.value)
	case ^parser.Yield_Expr:
		if e.value != nil { walk_expr(v, e.value) }
	case ^parser.Yield_From_Expr:
		walk_expr(v, e.value)
	case ^parser.Slice_Expr:
		if e.lower != nil { walk_expr(v, e.lower) }
		if e.upper != nil { walk_expr(v, e.upper) }
		if e.step != nil { walk_expr(v, e.step) }
	case ^parser.List_Comp:
		walk_expr(v, e.elt)
		for gen in e.generators {
			walk_expr(v, gen.iter)
			if gen.target != nil { walk_expr(v, gen.target) }
			for cond in gen.ifs { walk_expr(v, cond) }
		}
	case ^parser.Set_Comp:
		walk_expr(v, e.elt)
		for gen in e.generators {
			walk_expr(v, gen.iter)
			if gen.target != nil { walk_expr(v, gen.target) }
			for cond in gen.ifs { walk_expr(v, cond) }
		}
	case ^parser.Dict_Comp:
		walk_expr(v, e.key)
		walk_expr(v, e.value)
		for gen in e.generators {
			walk_expr(v, gen.iter)
			if gen.target != nil { walk_expr(v, gen.target) }
			for cond in gen.ifs { walk_expr(v, cond) }
		}
	case ^parser.Generator_Expr:
		walk_expr(v, e.elt)
		for gen in e.generators {
			walk_expr(v, gen.iter)
			if gen.target != nil { walk_expr(v, gen.target) }
			for cond in gen.ifs { walk_expr(v, cond) }
		}
	// Leaf nodes — no children to recurse
	case ^parser.Name_Expr:
	case ^parser.Constant_Expr:
	}
}

// Walk function argument annotations and defaults.
walk_func_args :: proc(v: ^AST_Visitor, args: ^parser.Arguments) {
	if args == nil { return }
	for &a in args.posonlyargs {
		if a.annotation != nil { walk_expr(v, a.annotation) }
	}
	for &a in args.args {
		if a.annotation != nil { walk_expr(v, a.annotation) }
	}
	for &a in args.kwonlyargs {
		if a.annotation != nil { walk_expr(v, a.annotation) }
	}
	if args.vararg != nil && args.vararg.annotation != nil {
		walk_expr(v, args.vararg.annotation)
	}
	if args.kwarg != nil && args.kwarg.annotation != nil {
		walk_expr(v, args.kwarg.annotation)
	}
	for d in args.defaults {
		if d != nil { walk_expr(v, d) }
	}
	for d in args.kw_defaults {
		if d != nil { walk_expr(v, d) }
	}
}

// Walk match pattern expressions recursively.
walk_pattern :: proc(v: ^AST_Visitor, pattern: parser.Pattern) {
	#partial switch p in pattern {
	case ^parser.Match_Value:
		walk_expr(v, p.value)
	case ^parser.Match_Sequence:
		for sub in p.patterns { walk_pattern(v, sub) }
	case ^parser.Match_Mapping:
		for k in p.keys { walk_expr(v, k) }
		for sub in p.patterns { walk_pattern(v, sub) }
	case ^parser.Match_Class:
		walk_expr(v, p.cls)
		for sub in p.patterns { walk_pattern(v, sub) }
		for sub in p.kwd_patterns { walk_pattern(v, sub) }
	case ^parser.Match_As:
		walk_pattern(v, p.pattern)
	case ^parser.Match_Or:
		for sub in p.patterns { walk_pattern(v, sub) }
	// Match_Singleton, Match_Star — no expressions to walk
	}
}
