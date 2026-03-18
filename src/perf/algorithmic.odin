package perf

import "core:fmt"
import parser "mimir:parser"
import core "mimir:core"

// PERF001 — String concatenation in loop is O(n²)
// NOTE: Kept as custom walker — needs loop body vs orelse distinction
// that the shared walker can't provide (both are traversed between
// visit_stmt/leave_stmt of the same For_Stmt).
check_string_concat_in_loop :: proc(ctx: ^Perf_Context) {
	ctx.current_scope = ctx.module.body
	walk_stmts_for_concat(ctx, ctx.module.body, false)
}

walk_stmts_for_concat :: proc(ctx: ^Perf_Context, stmts: []parser.Stmt, in_loop: bool) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Aug_Assign:
			if in_loop && s.op == .Add {
				name, name_ok := s.target.(^parser.Name_Expr)
				if name_ok {
					if was_string_init_before_loop(ctx, name.id) {
						append(&ctx.diagnostics, core.Diagnostic{
							severity = .Performance,
							location = core.Location{
								file   = ctx.file_path,
								line   = int(s.loc.line),
								column = int(s.loc.col),
							},
							what = "string concatenation in loop is O(n²)",
							why  = "each += copies the entire string; use a list and ''.join()",
							fix  = "collect items in a list, then use ''.join(items)",
							code = "PERF001",
						})
					}
				}
			}
		case ^parser.Assign:
			if in_loop {
				if bin, ok := s.value.(^parser.Bin_Op_Expr); ok && bin.op == .Add {
					for target in s.targets {
						if name, n_ok := target.(^parser.Name_Expr); n_ok {
							if lhs_name, l_ok := bin.left.(^parser.Name_Expr); l_ok && lhs_name.id == name.id {
								if was_string_init_before_loop(ctx, name.id) {
									append(&ctx.diagnostics, core.Diagnostic{
										severity = .Performance,
										location = core.Location{
											file   = ctx.file_path,
											line   = int(s.loc.line),
											column = int(s.loc.col),
										},
										what = "string concatenation in loop is O(n²)",
										why  = "each reassignment copies the entire string; use a list and ''.join()",
										fix  = "collect items in a list, then use ''.join(items)",
										code = "PERF001",
									})
								}
							}
						}
					}
				}
			}
		case ^parser.For_Stmt:
			walk_stmts_for_concat(ctx, s.body, true)
			walk_stmts_for_concat(ctx, s.orelse, in_loop)
		case ^parser.While_Stmt:
			walk_stmts_for_concat(ctx, s.body, true)
			walk_stmts_for_concat(ctx, s.orelse, in_loop)
		case ^parser.Func_Def:
			prev_scope := ctx.current_scope
			ctx.current_scope = s.body
			walk_stmts_for_concat(ctx, s.body, false)
			ctx.current_scope = prev_scope
		case ^parser.Async_Func_Def:
			prev_scope := ctx.current_scope
			ctx.current_scope = s.body
			walk_stmts_for_concat(ctx, s.body, false)
			ctx.current_scope = prev_scope
		case ^parser.Class_Def:
			prev_scope := ctx.current_scope
			ctx.current_scope = s.body
			walk_stmts_for_concat(ctx, s.body, false)
			ctx.current_scope = prev_scope
		case ^parser.If_Stmt:
			walk_stmts_for_concat(ctx, s.body, in_loop)
			walk_stmts_for_concat(ctx, s.orelse, in_loop)
		case ^parser.With_Stmt:
			walk_stmts_for_concat(ctx, s.body, in_loop)
		case ^parser.Try_Stmt:
			walk_stmts_for_concat(ctx, s.body, in_loop)
			for h in s.handlers { walk_stmts_for_concat(ctx, h.body, in_loop) }
			walk_stmts_for_concat(ctx, s.orelse, in_loop)
			walk_stmts_for_concat(ctx, s.finalbody, in_loop)
		}
	}
}

// Check if a variable was initialized to "" in preceding statements (same scope)
was_string_init_before_loop :: proc(ctx: ^Perf_Context, name: string) -> bool {
	// Use the innermost scope being walked, not module.body
	return check_string_init_in_scope(ctx.current_scope, name)
}

// Check if any Assign in the given statements initializes `name` to a string literal
// Does NOT recurse into function/class bodies (different scope)
check_string_init_in_scope :: proc(stmts: []parser.Stmt, name: string) -> bool {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Assign:
			if is_string_assign(s, name) { return true }
		case ^parser.If_Stmt:
			if check_string_init_in_scope(s.body, name) { return true }
			if check_string_init_in_scope(s.orelse, name) { return true }
		case ^parser.With_Stmt:
			if check_string_init_in_scope(s.body, name) { return true }
		case ^parser.Try_Stmt:
			if check_string_init_in_scope(s.body, name) { return true }
		}
	}
	return false
}

// Check if an Assign statement assigns a string constant to the given name
is_string_assign :: proc(assign: ^parser.Assign, name: string) -> bool {
	for target in assign.targets {
		n, ok := target.(^parser.Name_Expr)
		if !ok { continue }
		if n.id != name { continue }
		// Check if value is a string constant
		c, c_ok := assign.value.(^parser.Constant_Expr)
		if !c_ok { continue }
		_, is_str := c.value.(string)
		if is_str { return true }
	}
	return false
}

// PERF002 — Unnecessary list comprehension passed to a function that accepts generators
check_unnecessary_list_comp :: proc(ctx: ^Perf_Context) {
	visitor := core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			ctx := cast(^Perf_Context)raw_ctx
			check_expr_list_comp(ctx, expr)
		},
		ctx = rawptr(ctx),
	}
	core.walk_all_stmts(&visitor, ctx.module.body)
}

CONSUMER_FUNCS := [?]string{"sum", "any", "all", "min", "max", "sorted", "set", "frozenset", "tuple"}

check_expr_list_comp :: proc(ctx: ^Perf_Context, expr: parser.Expr) {
	if expr == nil { return }
	call, ok := expr.(^parser.Call_Expr)
	if !ok { return }
	if len(call.args) == 0 { return }

	// Check first arg is List_Comp
	_, is_list_comp := call.args[0].(^parser.List_Comp)
	if !is_list_comp { return }

	// Check callee is a known consumer function
	is_consumer := false

	// Direct name call: sum([...]), any([...]), etc.
	if name, name_ok := call.func.(^parser.Name_Expr); name_ok {
		for cf in CONSUMER_FUNCS {
			if name.id == cf {
				is_consumer = true
				break
			}
		}
	}

	// Method call: "".join([...])
	if attr, attr_ok := call.func.(^parser.Attribute_Expr); attr_ok {
		if attr.attr == "join" {
			is_consumer = true
		}
	}

	if is_consumer {
		append(&ctx.diagnostics, core.Diagnostic{
			severity = .Performance,
			location = core.Location{
				file   = ctx.file_path,
				line   = int(call.loc.line),
				column = int(call.loc.col),
			},
			what = "unnecessary list comprehension — pass a generator instead",
			why  = "the list is created in memory but immediately consumed; a generator avoids the allocation",
			fix  = "remove the square brackets to use a generator expression",
			code = "PERF002",
		})
	}
}

// PERF009 — sorted(sorted(x)) or sorted(list.sort()) — redundant double sort
check_redundant_sorted :: proc(ctx: ^Perf_Context) {
	visitor := core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			pctx := cast(^Perf_Context)raw_ctx
			call, ok := expr.(^parser.Call_Expr)
			if !ok { return }
			// Check: sorted(sorted(x)) or sorted(x.sort())
			name, name_ok := call.func.(^parser.Name_Expr)
			if !name_ok || name.id != "sorted" { return }
			if len(call.args) < 1 { return }
			// Inner is sorted(...)
			if inner_call, ic_ok := call.args[0].(^parser.Call_Expr); ic_ok {
				if inner_name, in_ok := inner_call.func.(^parser.Name_Expr); in_ok {
					if inner_name.id == "sorted" {
						append(&pctx.diagnostics, core.Diagnostic{
							severity = .Warning,
							location = core.Location{
								file   = pctx.file_path,
								line   = int(call.loc.line),
								column = int(call.loc.col),
							},
							what = "redundant double sort: sorted(sorted(x))",
							why  = "the inner sorted() already produces a sorted list — the outer sorted() is wasteful",
							fix  = "remove the outer sorted() call",
							code = "PERF009",
						})
					}
				}
			}
		},
		ctx = rawptr(ctx),
	}
	core.walk_all_stmts(&visitor, ctx.module.body)
}

// PERF010 — list([x for x in ...]) wrapping a list comprehension
check_list_wrap_comp :: proc(ctx: ^Perf_Context) {
	visitor := core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			pctx := cast(^Perf_Context)raw_ctx
			call, ok := expr.(^parser.Call_Expr)
			if !ok { return }
			name, name_ok := call.func.(^parser.Name_Expr)
			if !name_ok { return }
			if name.id != "list" && name.id != "set" && name.id != "tuple" { return }
			if len(call.args) != 1 { return }
			// Check if arg is a list/set comprehension
			is_comp := false
			#partial switch _ in call.args[0] {
			case ^parser.List_Comp: is_comp = true
			case ^parser.Set_Comp:  is_comp = true
			}
			if is_comp {
				append(&pctx.diagnostics, core.Diagnostic{
					severity = .Warning,
					location = core.Location{
						file   = pctx.file_path,
						line   = int(call.loc.line),
						column = int(call.loc.col),
					},
					what = fmt.tprintf("%s() wrapping a comprehension is redundant", name.id),
					why  = "the comprehension already produces the target type — wrapping in list()/set() copies unnecessarily",
					fix  = "use the comprehension directly without the wrapper call",
					code = "PERF010",
				})
			}
		},
		ctx = rawptr(ctx),
	}
	core.walk_all_stmts(&visitor, ctx.module.body)
}
