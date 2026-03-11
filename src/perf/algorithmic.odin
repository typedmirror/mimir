package perf

import "core:fmt"
import parser "mimir:parser"
import core "mimir:core"

// PERF001 — String concatenation in loop is O(n²)
check_string_concat_in_loop :: proc(ctx: ^Perf_Context) {
	walk_stmts_for_concat(ctx, ctx.module.body, false)
}

walk_stmts_for_concat :: proc(ctx: ^Perf_Context, stmts: []parser.Stmt, in_loop: bool) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Aug_Assign:
			if in_loop && s.op == .Add {
				// Check if target is a Name_Expr
				name, name_ok := s.target.(^parser.Name_Expr)
				if name_ok {
					// Check if this variable was initialized to a string before the loop
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
		case ^parser.For_Stmt:
			// Walk loop body with in_loop=true
			walk_stmts_for_concat(ctx, s.body, true)
			walk_stmts_for_concat(ctx, s.orelse, in_loop)
		case ^parser.While_Stmt:
			walk_stmts_for_concat(ctx, s.body, true)
			walk_stmts_for_concat(ctx, s.orelse, in_loop)
		case ^parser.Func_Def:
			walk_stmts_for_concat(ctx, s.body, false)
		case ^parser.Async_Func_Def:
			walk_stmts_for_concat(ctx, s.body, false)
		case ^parser.Class_Def:
			walk_stmts_for_concat(ctx, s.body, false)
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

// Check if a variable was initialized to "" in preceding statements (outside the current loop)
// We look backward from the loop statement that contains this aug_assign
was_string_init_before_loop :: proc(ctx: ^Perf_Context, name: string) -> bool {
	return check_string_init_in_scope(ctx.module.body, name)
}

// Recursively check if any Assign in the scope initializes `name` to a string literal
check_string_init_in_scope :: proc(stmts: []parser.Stmt, name: string) -> bool {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Assign:
			if is_string_assign(s, name) { return true }
		case ^parser.Func_Def:
			if check_string_init_in_scope(s.body, name) { return true }
		case ^parser.Async_Func_Def:
			if check_string_init_in_scope(s.body, name) { return true }
		case ^parser.Class_Def:
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
	walk_stmts_for_list_comp(ctx, ctx.module.body)
}

walk_stmts_for_list_comp :: proc(ctx: ^Perf_Context, stmts: []parser.Stmt) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Expr_Stmt:
			check_expr_list_comp(ctx, s.value)
		case ^parser.Assign:
			check_expr_list_comp(ctx, s.value)
		case ^parser.Ann_Assign:
			if s.value != nil { check_expr_list_comp(ctx, s.value) }
		case ^parser.Return_Stmt:
			if s.value != nil { check_expr_list_comp(ctx, s.value) }
		case ^parser.Func_Def:
			walk_stmts_for_list_comp(ctx, s.body)
		case ^parser.Async_Func_Def:
			walk_stmts_for_list_comp(ctx, s.body)
		case ^parser.Class_Def:
			walk_stmts_for_list_comp(ctx, s.body)
		case ^parser.If_Stmt:
			walk_stmts_for_list_comp(ctx, s.body)
			walk_stmts_for_list_comp(ctx, s.orelse)
		case ^parser.For_Stmt:
			walk_stmts_for_list_comp(ctx, s.body)
			walk_stmts_for_list_comp(ctx, s.orelse)
		case ^parser.While_Stmt:
			walk_stmts_for_list_comp(ctx, s.body)
			walk_stmts_for_list_comp(ctx, s.orelse)
		case ^parser.With_Stmt:
			walk_stmts_for_list_comp(ctx, s.body)
		case ^parser.Try_Stmt:
			walk_stmts_for_list_comp(ctx, s.body)
			for h in s.handlers { walk_stmts_for_list_comp(ctx, h.body) }
			walk_stmts_for_list_comp(ctx, s.orelse)
			walk_stmts_for_list_comp(ctx, s.finalbody)
		}
	}
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
