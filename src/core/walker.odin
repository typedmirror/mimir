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
	ctx:        rawptr,
}

// Walk all statements recursively, visiting every expression encountered.
walk_all_stmts :: proc(v: ^AST_Visitor, stmts: []parser.Stmt) {
	for stmt in stmts {
		walk_stmt(v, stmt)
	}
}

walk_stmt :: proc(v: ^AST_Visitor, stmt: parser.Stmt) {
	#partial switch s in stmt {
	case ^parser.Expr_Stmt:
		walk_expr(v, s.value)
	case ^parser.Assign:
		walk_expr(v, s.value)
		for t in s.targets { walk_expr(v, t) }
	case ^parser.Ann_Assign:
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
	case ^parser.Delete_Stmt:
		for t in s.targets { walk_expr(v, t) }

	// Compound statements — recurse into bodies
	case ^parser.Func_Def:
		for d in s.decorator_list { walk_expr(v, d) }
		walk_all_stmts(v, s.body)
	case ^parser.Async_Func_Def:
		for d in s.decorator_list { walk_expr(v, d) }
		walk_all_stmts(v, s.body)
	case ^parser.Class_Def:
		for d in s.decorator_list { walk_expr(v, d) }
		for b in s.bases { walk_expr(v, b) }
		walk_all_stmts(v, s.body)
	case ^parser.If_Stmt:
		walk_expr(v, s.test)
		walk_all_stmts(v, s.body)
		walk_all_stmts(v, s.orelse)
	case ^parser.For_Stmt:
		walk_expr(v, s.iter)
		walk_all_stmts(v, s.body)
		walk_all_stmts(v, s.orelse)
	case ^parser.Async_For:
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
			walk_all_stmts(v, h.body)
		}
		walk_all_stmts(v, s.orelse)
		walk_all_stmts(v, s.finalbody)
	case ^parser.Try_Star:
		walk_all_stmts(v, s.body)
		for h in s.handlers {
			walk_all_stmts(v, h.body)
		}
		walk_all_stmts(v, s.orelse)
		walk_all_stmts(v, s.finalbody)
	case ^parser.Match_Stmt:
		walk_expr(v, s.subject)
		for c in s.cases {
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
}

// Walk an expression tree recursively, calling visit_expr on every node.
walk_expr :: proc(v: ^AST_Visitor, expr: parser.Expr) {
	if expr == nil { return }
	v.visit_expr(expr, v.ctx)

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
