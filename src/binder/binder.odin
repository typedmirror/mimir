package binder

import "core:mem"
import parser "mimir:parser"
import core "mimir:core"

Bind_Result :: struct {
	symbols:      [dynamic]Symbol,
	scopes:       [dynamic]Scope,
	refs:         map[rawptr]Symbol_ID,
	imports:      [dynamic]Import_Record,
	diagnostics:  [dynamic]core.Diagnostic,
	module_scope: Scope_ID,
	file_path:    string,
	typing_names: map[string]string, // local_name → original_name (from typing/typing_extensions)
}

Binder :: struct {
	allocator:     mem.Allocator,
	result:        Bind_Result,
	scope_stack:   [dynamic]Scope_ID,
	file_path:     string,
	next_sym_id:   u32,
	next_scope_id: u32,
	has_star_import: bool,
}

bind :: proc(module: ^parser.Module, file_path: string, allocator: mem.Allocator) -> Bind_Result {
	b: Binder
	b.allocator = allocator
	b.file_path = file_path
	b.result.file_path = file_path
	b.result.symbols = make([dynamic]Symbol, 0, 256, allocator)
	b.result.scopes = make([dynamic]Scope, 0, 32, allocator)
	b.result.refs = make(map[rawptr]Symbol_ID, 256, allocator)
	b.result.imports = make([dynamic]Import_Record, 0, 16, allocator)
	b.result.diagnostics = make([dynamic]core.Diagnostic, 0, 16, allocator)
	b.result.typing_names = make(map[string]string, 8, allocator)
	b.scope_stack = make([dynamic]Scope_ID, 0, 16, allocator)

	// Builtins scope (always scope 1)
	init_builtins(&b)

	// Module scope (scope 2)
	mod_scope := push_scope(&b, .Module, "<module>", module.loc)
	b.result.module_scope = mod_scope

	// Pass 1: collect all definitions
	collect_defs_stmts(&b, module.body)

	// Pass 2: resolve all references
	// Re-enter module scope for pass 2
	pop_scope(&b) // pop module
	pop_scope(&b) // pop builtins
	append(&b.scope_stack, Scope_ID(1)) // builtins
	append(&b.scope_stack, mod_scope)   // module

	resolve_refs_stmts(&b, module.body)

	return b.result
}

// ==================== Pass 1: Definition Collection ====================

collect_defs_stmts :: proc(b: ^Binder, stmts: []parser.Stmt) {
	// First pass: process global/nonlocal declarations
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Global_Stmt:
			collect_global(b, s)
		case ^parser.Nonlocal_Stmt:
			collect_nonlocal(b, s)
		}
	}
	// Second: process all definitions
	for stmt in stmts {
		collect_defs_stmt(b, stmt)
	}
}

collect_defs_stmt :: proc(b: ^Binder, stmt: parser.Stmt) {
	#partial switch s in stmt {
	case ^parser.Func_Def:
		add_symbol(b, s.name, .Function, {.Is_Assigned}, s.loc)
		child := push_scope(b, .Function, s.name, s.loc)
		add_params(b, &s.args, s.loc)
		collect_defs_stmts(b, s.body)
		for dec in s.decorator_list { scan_expr_for_scopes(b, dec) }
		if s.returns != nil { scan_expr_for_scopes(b, s.returns) }
		pop_scope(b)

	case ^parser.Async_Func_Def:
		add_symbol(b, s.name, .Function, {.Is_Assigned}, s.loc)
		child := push_scope(b, .Function, s.name, s.loc)
		add_params(b, &s.args, s.loc)
		collect_defs_stmts(b, s.body)
		for dec in s.decorator_list { scan_expr_for_scopes(b, dec) }
		if s.returns != nil { scan_expr_for_scopes(b, s.returns) }
		pop_scope(b)

	case ^parser.Class_Def:
		add_symbol(b, s.name, .Class, {.Is_Assigned}, s.loc)
		child := push_scope(b, .Class, s.name, s.loc)
		collect_defs_stmts(b, s.body)
		for base in s.bases { scan_expr_for_scopes(b, base) }
		for dec in s.decorator_list { scan_expr_for_scopes(b, dec) }
		pop_scope(b)

	case ^parser.Assign:
		for target in s.targets {
			collect_def_target(b, target)
		}
		scan_expr_for_scopes(b, s.value)

	case ^parser.Aug_Assign:
		collect_def_target(b, s.target)
		scan_expr_for_scopes(b, s.value)

	case ^parser.Ann_Assign:
		if s.simple {
			collect_def_target_annotated(b, s.target)
		}
		scan_expr_for_scopes(b, s.annotation)
		if s.value != nil { scan_expr_for_scopes(b, s.value) }

	case ^parser.For_Stmt:
		collect_def_target(b, s.target)
		scan_expr_for_scopes(b, s.iter)
		collect_defs_stmts(b, s.body)
		collect_defs_stmts(b, s.orelse)

	case ^parser.Async_For:
		collect_def_target(b, s.target)
		scan_expr_for_scopes(b, s.iter)
		collect_defs_stmts(b, s.body)
		collect_defs_stmts(b, s.orelse)

	case ^parser.While_Stmt:
		scan_expr_for_scopes(b, s.test)
		collect_defs_stmts(b, s.body)
		collect_defs_stmts(b, s.orelse)

	case ^parser.If_Stmt:
		scan_expr_for_scopes(b, s.test)
		collect_defs_stmts(b, s.body)
		collect_defs_stmts(b, s.orelse)

	case ^parser.With_Stmt:
		for item in s.items {
			scan_expr_for_scopes(b, item.context_expr)
			if item.optional_vars != nil {
				collect_def_target(b, item.optional_vars)
			}
		}
		collect_defs_stmts(b, s.body)

	case ^parser.Async_With:
		for item in s.items {
			scan_expr_for_scopes(b, item.context_expr)
			if item.optional_vars != nil {
				collect_def_target(b, item.optional_vars)
			}
		}
		collect_defs_stmts(b, s.body)

	case ^parser.Try_Stmt:
		collect_defs_stmts(b, s.body)
		for handler in s.handlers {
			if len(handler.name) > 0 {
				add_symbol(b, handler.name, .Variable, {.Is_Assigned}, handler.loc)
			}
			collect_defs_stmts(b, handler.body)
		}
		collect_defs_stmts(b, s.orelse)
		collect_defs_stmts(b, s.finalbody)

	case ^parser.Try_Star:
		collect_defs_stmts(b, s.body)
		for handler in s.handlers {
			if len(handler.name) > 0 {
				add_symbol(b, handler.name, .Variable, {.Is_Assigned}, handler.loc)
			}
			collect_defs_stmts(b, handler.body)
		}
		collect_defs_stmts(b, s.orelse)
		collect_defs_stmts(b, s.finalbody)

	case ^parser.Match_Stmt:
		scan_expr_for_scopes(b, s.subject)
		for mc in s.cases {
			collect_defs_pattern(b, mc.pattern)
			if mc.guard != nil { scan_expr_for_scopes(b, mc.guard) }
			collect_defs_stmts(b, mc.body)
		}

	case ^parser.Import_Stmt:
		record_import(b, s)

	case ^parser.Import_From:
		record_import_from(b, s)

	case ^parser.Type_Alias_Stmt:
		// Type alias name binding
		#partial switch n in s.name {
		case ^parser.Name_Expr:
			add_symbol(b, n.id, .Variable, {.Is_Assigned}, s.loc)
		}
		for tp in s.type_params {
			collect_type_param(b, tp)
		}
		scan_expr_for_scopes(b, s.value)

	case ^parser.Expr_Stmt:
		scan_expr_for_scopes(b, s.value)

	case ^parser.Return_Stmt:
		if s.value != nil { scan_expr_for_scopes(b, s.value) }

	case ^parser.Delete_Stmt:
		// del doesn't create bindings

	case ^parser.Raise_Stmt:
		if s.exc != nil { scan_expr_for_scopes(b, s.exc) }
		if s.cause != nil { scan_expr_for_scopes(b, s.cause) }

	case ^parser.Assert_Stmt:
		scan_expr_for_scopes(b, s.test)
		if s.msg != nil { scan_expr_for_scopes(b, s.msg) }

	case ^parser.Global_Stmt, ^parser.Nonlocal_Stmt:
		// Already handled in first pass

	case ^parser.Pass_Stmt, ^parser.Break_Stmt, ^parser.Continue_Stmt:
		// No names
	}
}

collect_global :: proc(b: ^Binder, s: ^parser.Global_Stmt) {
	scope := get_scope(b, current_scope(b))
	if scope == nil { return }

	for name in s.names {
		// Check for global+nonlocal conflict
		if existing, ok := scope.symbols[name]; ok {
			sym := get_symbol(b, existing)
			if sym != nil && .Is_Nonlocal in sym.flags {
				append(&b.result.diagnostics, core.Diagnostic{
					severity = .Error,
					location = core.Location{
						file   = b.file_path,
						line   = int(s.loc.line),
						column = int(s.loc.col),
					},
					what = "name is both global and nonlocal",
					why  = "a name cannot be declared both global and nonlocal in the same scope",
					fix  = "remove one of the declarations",
					code = "B004",
				})
				continue
			}
		}
		add_symbol(b, name, .Variable, {.Is_Global}, s.loc)
	}
}

collect_nonlocal :: proc(b: ^Binder, s: ^parser.Nonlocal_Stmt) {
	scope := get_scope(b, current_scope(b))
	if scope == nil { return }

	// nonlocal at module level is an error
	if scope.kind == .Module {
		append(&b.result.diagnostics, core.Diagnostic{
			severity = .Error,
			location = core.Location{
				file   = b.file_path,
				line   = int(s.loc.line),
				column = int(s.loc.col),
			},
			what = "nonlocal declaration at module level",
			why  = "nonlocal can only be used inside a function",
			fix  = "remove the nonlocal declaration or move it inside a function",
			code = "B002",
		})
		return
	}

	for name in s.names {
		// Check for global+nonlocal conflict
		if existing, ok := scope.symbols[name]; ok {
			sym := get_symbol(b, existing)
			if sym != nil && .Is_Global in sym.flags {
				append(&b.result.diagnostics, core.Diagnostic{
					severity = .Error,
					location = core.Location{
						file   = b.file_path,
						line   = int(s.loc.line),
						column = int(s.loc.col),
					},
					what = "name is both global and nonlocal",
					why  = "a name cannot be declared both global and nonlocal in the same scope",
					fix  = "remove one of the declarations",
					code = "B004",
				})
				continue
			}
		}
		add_symbol(b, name, .Variable, {.Is_Nonlocal}, s.loc)
	}
}

collect_def_target :: proc(b: ^Binder, expr: parser.Expr) {
	if expr == nil { return }
	#partial switch e in expr {
	case ^parser.Name_Expr:
		// Check if marked global or nonlocal — don't add as local
		scope := get_scope(b, current_scope(b))
		if scope != nil {
			if existing, ok := scope.symbols[e.id]; ok {
				sym := get_symbol(b, existing)
				if sym != nil && (.Is_Global in sym.flags || .Is_Nonlocal in sym.flags) {
					sym.flags += {.Is_Assigned}
					return
				}
			}
		}
		add_symbol(b, e.id, .Variable, {.Is_Assigned}, e.loc)
	case ^parser.Tuple_Expr:
		for elt in e.elts { collect_def_target(b, elt) }
	case ^parser.List_Expr:
		for elt in e.elts { collect_def_target(b, elt) }
	case ^parser.Starred_Expr:
		collect_def_target(b, e.value)
	case ^parser.Attribute_Expr, ^parser.Subscript_Expr:
		// Not local name bindings — attribute/subscript assignment
	}
}

collect_def_target_annotated :: proc(b: ^Binder, expr: parser.Expr) {
	if expr == nil { return }
	#partial switch e in expr {
	case ^parser.Name_Expr:
		scope := get_scope(b, current_scope(b))
		if scope != nil {
			if existing, ok := scope.symbols[e.id]; ok {
				sym := get_symbol(b, existing)
				if sym != nil {
					sym.flags += {.Is_Annotated}
					return
				}
			}
		}
		add_symbol(b, e.id, .Variable, {.Is_Annotated}, e.loc)
	}
}

collect_defs_pattern :: proc(b: ^Binder, pat: parser.Pattern) {
	if pat == nil { return }
	#partial switch p in pat {
	case ^parser.Match_As:
		if len(p.name) > 0 {
			add_symbol(b, p.name, .Variable, {.Is_Assigned}, p.loc)
		}
		collect_defs_pattern(b, p.pattern)
	case ^parser.Match_Star:
		if len(p.name) > 0 {
			add_symbol(b, p.name, .Variable, {.Is_Assigned}, p.loc)
		}
	case ^parser.Match_Mapping:
		if len(p.rest) > 0 {
			add_symbol(b, p.rest, .Variable, {.Is_Assigned}, p.loc)
		}
		for sub_pat in p.patterns { collect_defs_pattern(b, sub_pat) }
	case ^parser.Match_Sequence:
		for sub_pat in p.patterns { collect_defs_pattern(b, sub_pat) }
	case ^parser.Match_Or:
		for sub_pat in p.patterns { collect_defs_pattern(b, sub_pat) }
	case ^parser.Match_Class:
		for sub_pat in p.patterns { collect_defs_pattern(b, sub_pat) }
		for sub_pat in p.kwd_patterns { collect_defs_pattern(b, sub_pat) }
	}
}

collect_type_param :: proc(b: ^Binder, tp: parser.Type_Param) {
	#partial switch t in tp {
	case ^parser.Type_Var_Param:
		add_symbol(b, t.name, .Type_Param, {}, t.loc)
	case ^parser.Param_Spec_Param:
		add_symbol(b, t.name, .Type_Param, {}, t.loc)
	case ^parser.Type_Var_Tuple_Param:
		add_symbol(b, t.name, .Type_Param, {}, t.loc)
	}
}

add_params :: proc(b: ^Binder, args: ^parser.Arguments, loc: parser.Src_Loc) {
	for arg in args.posonlyargs {
		add_symbol(b, arg.arg, .Parameter, {.Is_Param}, arg.loc)
	}
	for arg in args.args {
		add_symbol(b, arg.arg, .Parameter, {.Is_Param}, arg.loc)
	}
	if args.vararg != nil {
		add_symbol(b, args.vararg.arg, .Parameter, {.Is_Param}, args.vararg.loc)
	}
	for arg in args.kwonlyargs {
		add_symbol(b, arg.arg, .Parameter, {.Is_Param}, arg.loc)
	}
	if args.kwarg != nil {
		add_symbol(b, args.kwarg.arg, .Parameter, {.Is_Param}, args.kwarg.loc)
	}
}

// scan_expr_for_scopes: during pass 1, walk expressions to find
// lambdas and comprehensions that create new scopes.
scan_expr_for_scopes :: proc(b: ^Binder, expr: parser.Expr) {
	if expr == nil { return }
	#partial switch e in expr {
	case ^parser.Lambda_Expr:
		push_scope(b, .Lambda, "<lambda>", e.loc)
		add_params(b, &e.args, e.loc)
		scan_expr_for_scopes(b, e.body)
		pop_scope(b)

	case ^parser.List_Comp:
		push_scope(b, .Comprehension, "<listcomp>", e.loc)
		for gen in e.generators {
			collect_def_target(b, gen.target)
			scan_expr_for_scopes(b, gen.iter)
			for if_expr in gen.ifs { scan_expr_for_scopes(b, if_expr) }
		}
		scan_expr_for_scopes(b, e.elt)
		pop_scope(b)

	case ^parser.Set_Comp:
		push_scope(b, .Comprehension, "<setcomp>", e.loc)
		for gen in e.generators {
			collect_def_target(b, gen.target)
			scan_expr_for_scopes(b, gen.iter)
			for if_expr in gen.ifs { scan_expr_for_scopes(b, if_expr) }
		}
		scan_expr_for_scopes(b, e.elt)
		pop_scope(b)

	case ^parser.Dict_Comp:
		push_scope(b, .Comprehension, "<dictcomp>", e.loc)
		for gen in e.generators {
			collect_def_target(b, gen.target)
			scan_expr_for_scopes(b, gen.iter)
			for if_expr in gen.ifs { scan_expr_for_scopes(b, if_expr) }
		}
		scan_expr_for_scopes(b, e.key)
		scan_expr_for_scopes(b, e.value)
		pop_scope(b)

	case ^parser.Generator_Expr:
		push_scope(b, .Comprehension, "<genexpr>", e.loc)
		for gen in e.generators {
			collect_def_target(b, gen.target)
			scan_expr_for_scopes(b, gen.iter)
			for if_expr in gen.ifs { scan_expr_for_scopes(b, if_expr) }
		}
		scan_expr_for_scopes(b, e.elt)
		pop_scope(b)

	case ^parser.Named_Expr:
		// Walrus operator: in a comprehension, binds in the ENCLOSING scope
		scope := get_scope(b, current_scope(b))
		if scope != nil && scope.kind == .Comprehension {
			// Temporarily pop to enclosing scope to add the binding
			saved := current_scope(b)
			pop_scope(b)
			collect_def_target(b, e.target)
			append(&b.scope_stack, saved)
		} else {
			collect_def_target(b, e.target)
		}
		scan_expr_for_scopes(b, e.value)

	case ^parser.Call_Expr:
		scan_expr_for_scopes(b, e.func)
		for arg in e.args { scan_expr_for_scopes(b, arg) }
		for kw in e.keywords { scan_expr_for_scopes(b, kw.value) }

	case ^parser.If_Expr:
		scan_expr_for_scopes(b, e.test)
		scan_expr_for_scopes(b, e.body)
		scan_expr_for_scopes(b, e.orelse)

	case ^parser.Bool_Op_Expr:
		for v in e.values { scan_expr_for_scopes(b, v) }

	case ^parser.Bin_Op_Expr:
		scan_expr_for_scopes(b, e.left)
		scan_expr_for_scopes(b, e.right)

	case ^parser.Unary_Op_Expr:
		scan_expr_for_scopes(b, e.operand)

	case ^parser.Compare_Expr:
		scan_expr_for_scopes(b, e.left)
		for c in e.comparators { scan_expr_for_scopes(b, c) }

	case ^parser.Dict_Expr:
		for k in e.keys { scan_expr_for_scopes(b, k) }
		for v in e.values { scan_expr_for_scopes(b, v) }

	case ^parser.Set_Expr:
		for elt in e.elts { scan_expr_for_scopes(b, elt) }

	case ^parser.List_Expr:
		for elt in e.elts { scan_expr_for_scopes(b, elt) }

	case ^parser.Tuple_Expr:
		for elt in e.elts { scan_expr_for_scopes(b, elt) }

	case ^parser.Attribute_Expr:
		scan_expr_for_scopes(b, e.value)

	case ^parser.Subscript_Expr:
		scan_expr_for_scopes(b, e.value)
		scan_expr_for_scopes(b, e.slice)

	case ^parser.Starred_Expr:
		scan_expr_for_scopes(b, e.value)

	case ^parser.Await_Expr:
		scan_expr_for_scopes(b, e.value)

	case ^parser.Yield_Expr:
		if e.value != nil { scan_expr_for_scopes(b, e.value) }

	case ^parser.Yield_From_Expr:
		scan_expr_for_scopes(b, e.value)

	case ^parser.Formatted_Value:
		scan_expr_for_scopes(b, e.value)
		if e.format_spec != nil { scan_expr_for_scopes(b, e.format_spec) }

	case ^parser.Joined_Str:
		for v in e.values { scan_expr_for_scopes(b, v) }

	case ^parser.Slice_Expr:
		if e.lower != nil { scan_expr_for_scopes(b, e.lower) }
		if e.upper != nil { scan_expr_for_scopes(b, e.upper) }
		if e.step != nil { scan_expr_for_scopes(b, e.step) }

	// Leaf expressions — no sub-expressions to scan
	case ^parser.Name_Expr, ^parser.Constant_Expr:
		// nothing
	}
}

// ==================== Pass 2: Reference Resolution ====================

resolve_refs_stmts :: proc(b: ^Binder, stmts: []parser.Stmt) {
	for stmt in stmts {
		resolve_refs_stmt(b, stmt)
	}
}

resolve_refs_stmt :: proc(b: ^Binder, stmt: parser.Stmt) {
	#partial switch s in stmt {
	case ^parser.Func_Def:
		// Decorators resolve in CURRENT scope
		for dec in s.decorator_list { resolve_refs_expr(b, dec) }
		if s.returns != nil { resolve_refs_expr(b, s.returns) }
		// Default values resolve in CURRENT scope
		resolve_param_defaults(b, &s.args)
		// Body resolves in CHILD scope
		child := find_child_scope(b, current_scope(b), s.name, .Function, s.loc)
		if child != INVALID_SCOPE {
			append(&b.scope_stack, child)
			resolve_param_annotations(b, &s.args)
			resolve_refs_stmts(b, s.body)
			pop_scope(b)
		}

	case ^parser.Async_Func_Def:
		for dec in s.decorator_list { resolve_refs_expr(b, dec) }
		if s.returns != nil { resolve_refs_expr(b, s.returns) }
		resolve_param_defaults(b, &s.args)
		child := find_child_scope(b, current_scope(b), s.name, .Function, s.loc)
		if child != INVALID_SCOPE {
			append(&b.scope_stack, child)
			resolve_param_annotations(b, &s.args)
			resolve_refs_stmts(b, s.body)
			pop_scope(b)
		}

	case ^parser.Class_Def:
		for dec in s.decorator_list { resolve_refs_expr(b, dec) }
		for base in s.bases { resolve_refs_expr(b, base) }
		for kw in s.keywords { resolve_refs_expr(b, kw.value) }
		child := find_child_scope(b, current_scope(b), s.name, .Class, s.loc)
		if child != INVALID_SCOPE {
			append(&b.scope_stack, child)
			resolve_refs_stmts(b, s.body)
			pop_scope(b)
		}

	case ^parser.Assign:
		resolve_refs_expr(b, s.value)
		for target in s.targets { resolve_refs_expr(b, target) }

	case ^parser.Aug_Assign:
		resolve_refs_expr(b, s.value)
		resolve_refs_expr(b, s.target)

	case ^parser.Ann_Assign:
		resolve_refs_expr(b, s.annotation)
		if s.value != nil { resolve_refs_expr(b, s.value) }
		resolve_refs_expr(b, s.target)

	case ^parser.For_Stmt:
		resolve_refs_expr(b, s.iter)
		resolve_refs_expr(b, s.target)
		resolve_refs_stmts(b, s.body)
		resolve_refs_stmts(b, s.orelse)

	case ^parser.Async_For:
		resolve_refs_expr(b, s.iter)
		resolve_refs_expr(b, s.target)
		resolve_refs_stmts(b, s.body)
		resolve_refs_stmts(b, s.orelse)

	case ^parser.While_Stmt:
		resolve_refs_expr(b, s.test)
		resolve_refs_stmts(b, s.body)
		resolve_refs_stmts(b, s.orelse)

	case ^parser.If_Stmt:
		resolve_refs_expr(b, s.test)
		resolve_refs_stmts(b, s.body)
		resolve_refs_stmts(b, s.orelse)

	case ^parser.With_Stmt:
		for item in s.items {
			resolve_refs_expr(b, item.context_expr)
			if item.optional_vars != nil { resolve_refs_expr(b, item.optional_vars) }
		}
		resolve_refs_stmts(b, s.body)

	case ^parser.Async_With:
		for item in s.items {
			resolve_refs_expr(b, item.context_expr)
			if item.optional_vars != nil { resolve_refs_expr(b, item.optional_vars) }
		}
		resolve_refs_stmts(b, s.body)

	case ^parser.Try_Stmt:
		resolve_refs_stmts(b, s.body)
		for handler in s.handlers {
			if handler.type != nil { resolve_refs_expr(b, handler.type) }
			resolve_refs_stmts(b, handler.body)
		}
		resolve_refs_stmts(b, s.orelse)
		resolve_refs_stmts(b, s.finalbody)

	case ^parser.Try_Star:
		resolve_refs_stmts(b, s.body)
		for handler in s.handlers {
			if handler.type != nil { resolve_refs_expr(b, handler.type) }
			resolve_refs_stmts(b, handler.body)
		}
		resolve_refs_stmts(b, s.orelse)
		resolve_refs_stmts(b, s.finalbody)

	case ^parser.Match_Stmt:
		resolve_refs_expr(b, s.subject)
		for mc in s.cases {
			resolve_refs_pattern(b, mc.pattern)
			if mc.guard != nil { resolve_refs_expr(b, mc.guard) }
			resolve_refs_stmts(b, mc.body)
		}

	case ^parser.Return_Stmt:
		if s.value != nil { resolve_refs_expr(b, s.value) }

	case ^parser.Delete_Stmt:
		for target in s.targets { resolve_refs_expr(b, target) }

	case ^parser.Raise_Stmt:
		if s.exc != nil { resolve_refs_expr(b, s.exc) }
		if s.cause != nil { resolve_refs_expr(b, s.cause) }

	case ^parser.Assert_Stmt:
		resolve_refs_expr(b, s.test)
		if s.msg != nil { resolve_refs_expr(b, s.msg) }

	case ^parser.Expr_Stmt:
		resolve_refs_expr(b, s.value)

	case ^parser.Type_Alias_Stmt:
		resolve_refs_expr(b, s.value)

	case ^parser.Global_Stmt, ^parser.Nonlocal_Stmt:
		// No expressions
	case ^parser.Import_Stmt, ^parser.Import_From:
		// Imports handled in pass 1
	case ^parser.Pass_Stmt, ^parser.Break_Stmt, ^parser.Continue_Stmt:
		// No expressions
	}
}

resolve_refs_expr :: proc(b: ^Binder, expr: parser.Expr) {
	if expr == nil { return }
	#partial switch e in expr {
	case ^parser.Name_Expr:
		sym_id, found := resolve_name(b, e.id, current_scope(b))
		if found {
			b.result.refs[rawptr(e)] = sym_id
		} else if e.ctx == .Load && !b.has_star_import {
			append(&b.result.diagnostics, core.Diagnostic{
				severity = .Error,
				location = core.Location{
					file   = b.file_path,
					line   = int(e.loc.line),
					column = int(e.loc.col),
				},
				what = fmt_undefined_name(e.id, b.allocator),
				why  = "this name is not defined in any accessible scope",
				fix  = "check spelling, add an import, or define the variable before use",
				code = "B001",
			})
		}

	case ^parser.Call_Expr:
		resolve_refs_expr(b, e.func)
		for arg in e.args { resolve_refs_expr(b, arg) }
		for kw in e.keywords { resolve_refs_expr(b, kw.value) }

	case ^parser.Attribute_Expr:
		resolve_refs_expr(b, e.value)

	case ^parser.Subscript_Expr:
		resolve_refs_expr(b, e.value)
		resolve_refs_expr(b, e.slice)

	case ^parser.Starred_Expr:
		resolve_refs_expr(b, e.value)

	case ^parser.Bool_Op_Expr:
		for v in e.values { resolve_refs_expr(b, v) }

	case ^parser.Bin_Op_Expr:
		resolve_refs_expr(b, e.left)
		resolve_refs_expr(b, e.right)

	case ^parser.Unary_Op_Expr:
		resolve_refs_expr(b, e.operand)

	case ^parser.Compare_Expr:
		resolve_refs_expr(b, e.left)
		for c in e.comparators { resolve_refs_expr(b, c) }

	case ^parser.If_Expr:
		resolve_refs_expr(b, e.test)
		resolve_refs_expr(b, e.body)
		resolve_refs_expr(b, e.orelse)

	case ^parser.Named_Expr:
		resolve_refs_expr(b, e.value)
		// target is a Store — already bound in pass 1

	case ^parser.Lambda_Expr:
		resolve_param_defaults(b, &e.args)
		child := find_child_scope_by_kind(b, current_scope(b), .Lambda, e.loc)
		if child != INVALID_SCOPE {
			append(&b.scope_stack, child)
			resolve_refs_expr(b, e.body)
			pop_scope(b)
		}

	case ^parser.List_Comp:
		resolve_comp(b, e.generators, e.elt, nil, e.loc)
	case ^parser.Set_Comp:
		resolve_comp(b, e.generators, e.elt, nil, e.loc)
	case ^parser.Generator_Expr:
		resolve_comp(b, e.generators, e.elt, nil, e.loc)
	case ^parser.Dict_Comp:
		resolve_comp(b, e.generators, e.key, e.value, e.loc)

	case ^parser.Dict_Expr:
		for k in e.keys { resolve_refs_expr(b, k) }
		for v in e.values { resolve_refs_expr(b, v) }

	case ^parser.Set_Expr:
		for elt in e.elts { resolve_refs_expr(b, elt) }

	case ^parser.List_Expr:
		for elt in e.elts { resolve_refs_expr(b, elt) }

	case ^parser.Tuple_Expr:
		for elt in e.elts { resolve_refs_expr(b, elt) }

	case ^parser.Await_Expr:
		resolve_refs_expr(b, e.value)

	case ^parser.Yield_Expr:
		if e.value != nil { resolve_refs_expr(b, e.value) }

	case ^parser.Yield_From_Expr:
		resolve_refs_expr(b, e.value)

	case ^parser.Formatted_Value:
		resolve_refs_expr(b, e.value)
		if e.format_spec != nil { resolve_refs_expr(b, e.format_spec) }

	case ^parser.Joined_Str:
		for v in e.values { resolve_refs_expr(b, v) }

	case ^parser.Slice_Expr:
		if e.lower != nil { resolve_refs_expr(b, e.lower) }
		if e.upper != nil { resolve_refs_expr(b, e.upper) }
		if e.step != nil { resolve_refs_expr(b, e.step) }

	case ^parser.Constant_Expr:
		// leaf
	}
}

resolve_refs_pattern :: proc(b: ^Binder, pat: parser.Pattern) {
	if pat == nil { return }
	#partial switch p in pat {
	case ^parser.Match_Value:
		resolve_refs_expr(b, p.value)
	case ^parser.Match_Class:
		resolve_refs_expr(b, p.cls)
		for sub in p.patterns { resolve_refs_pattern(b, sub) }
		for sub in p.kwd_patterns { resolve_refs_pattern(b, sub) }
	case ^parser.Match_Sequence:
		for sub in p.patterns { resolve_refs_pattern(b, sub) }
	case ^parser.Match_Mapping:
		for k in p.keys { resolve_refs_expr(b, k) }
		for sub in p.patterns { resolve_refs_pattern(b, sub) }
	case ^parser.Match_As:
		resolve_refs_pattern(b, p.pattern)
	case ^parser.Match_Or:
		for sub in p.patterns { resolve_refs_pattern(b, sub) }
	}
}

resolve_comp :: proc(b: ^Binder, generators: []parser.Comprehension, elt: parser.Expr, value: parser.Expr, loc: parser.Src_Loc) {
	// First iterator resolves in OUTER scope
	if len(generators) > 0 {
		resolve_refs_expr(b, generators[0].iter)
	}

	child := find_child_scope_by_kind(b, current_scope(b), .Comprehension, loc)
	if child == INVALID_SCOPE { return }

	append(&b.scope_stack, child)

	// First generator target + ifs in comp scope
	if len(generators) > 0 {
		resolve_refs_expr(b, generators[0].target)
		for if_expr in generators[0].ifs { resolve_refs_expr(b, if_expr) }
	}

	// Remaining generators fully in comp scope
	for gen in generators[1:] {
		resolve_refs_expr(b, gen.iter)
		resolve_refs_expr(b, gen.target)
		for if_expr in gen.ifs { resolve_refs_expr(b, if_expr) }
	}

	resolve_refs_expr(b, elt)
	if value != nil { resolve_refs_expr(b, value) }

	pop_scope(b)
}

resolve_param_defaults :: proc(b: ^Binder, args: ^parser.Arguments) {
	for d in args.defaults { resolve_refs_expr(b, d) }
	for d in args.kw_defaults { resolve_refs_expr(b, d) }
}

resolve_param_annotations :: proc(b: ^Binder, args: ^parser.Arguments) {
	for arg in args.posonlyargs { if arg.annotation != nil { resolve_refs_expr(b, arg.annotation) } }
	for arg in args.args { if arg.annotation != nil { resolve_refs_expr(b, arg.annotation) } }
	if args.vararg != nil && args.vararg.annotation != nil { resolve_refs_expr(b, args.vararg.annotation) }
	for arg in args.kwonlyargs { if arg.annotation != nil { resolve_refs_expr(b, arg.annotation) } }
	if args.kwarg != nil && args.kwarg.annotation != nil { resolve_refs_expr(b, args.kwarg.annotation) }
}

// ==================== Scope Lookup Helpers ====================

find_child_scope :: proc(b: ^Binder, parent_id: Scope_ID, name: string, kind: Scope_Kind, loc: parser.Src_Loc = {}) -> Scope_ID {
	for &scope in b.result.scopes {
		if scope.parent_id == parent_id && scope.name == name && scope.kind == kind {
			// If loc provided, match by location to disambiguate same-name scopes
			if loc.line != 0 && (scope.loc.line != loc.line || scope.loc.col != loc.col) {
				continue
			}
			return scope.id
		}
	}
	return INVALID_SCOPE
}

find_child_scope_by_kind :: proc(b: ^Binder, parent_id: Scope_ID, kind: Scope_Kind, loc: parser.Src_Loc) -> Scope_ID {
	for &scope in b.result.scopes {
		if scope.parent_id == parent_id && scope.kind == kind && scope.loc.line == loc.line && scope.loc.col == loc.col {
			return scope.id
		}
	}
	return INVALID_SCOPE
}

// ==================== Helpers ====================

// Lookup helpers for downstream phases
get_ref :: proc(result: ^Bind_Result, name_expr: rawptr) -> (Symbol_ID, bool) {
	if sym_id, ok := result.refs[name_expr]; ok {
		return sym_id, true
	}
	return INVALID_SYMBOL, false
}

result_get_symbol :: proc(result: ^Bind_Result, id: Symbol_ID) -> ^Symbol {
	idx := int(id) - 1
	if idx < 0 || idx >= len(result.symbols) {
		return nil
	}
	return &result.symbols[idx]
}

result_get_scope :: proc(result: ^Bind_Result, id: Scope_ID) -> ^Scope {
	idx := int(id) - 1
	if idx < 0 || idx >= len(result.scopes) {
		return nil
	}
	return &result.scopes[idx]
}

fmt_undefined_name :: proc(name: string, allocator: mem.Allocator) -> string {
	// Simple string concat for diagnostic message
	prefix := "undefined name '"
	suffix := "'"
	buf := make([]byte, len(prefix) + len(name) + len(suffix), allocator)
	copy(buf, prefix)
	copy(buf[len(prefix):], name)
	copy(buf[len(prefix) + len(name):], suffix)
	return string(buf)
}
