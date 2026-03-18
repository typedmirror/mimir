package flow

import "core:mem"
import parser "mimir:parser"
import binder "mimir:binder"
import core "mimir:core"

// ==================== Combined Result ====================

Flow_Result :: struct {
	cfgs:         [dynamic]CFG,
	scope_to_cfg: map[binder.Scope_ID]int,
	guards:       [dynamic]Guard,
	dfgs:         map[binder.Scope_ID]DFG,
	const_maps:   map[binder.Scope_ID]Const_Map,
	diagnostics:  [dynamic]core.Diagnostic,
}

// ==================== Entry Point ====================

analyze :: proc(module: ^parser.Module, bind_result: ^binder.Bind_Result, file_path: string, allocator: mem.Allocator) -> Flow_Result {
	result: Flow_Result
	result.cfgs = make([dynamic]CFG, 0, 16, allocator)
	result.scope_to_cfg = make(map[binder.Scope_ID]int, 16, allocator)
	result.guards = make([dynamic]Guard, 0, 16, allocator)
	result.diagnostics = make([dynamic]core.Diagnostic, 0, 8, allocator)
	result.dfgs = make(map[binder.Scope_ID]DFG, 16, allocator)
	result.const_maps = make(map[binder.Scope_ID]Const_Map, 16, allocator)

	// Build CFG for module body
	module_cfg := build_cfg_for_stmts(
		module.body, bind_result.module_scope, "<module>",
		bind_result, file_path, &result.diagnostics, allocator,
	)
	compute_reachability(&module_cfg)
	append(&result.cfgs, module_cfg)
	result.scope_to_cfg[bind_result.module_scope] = 0

	// Walk AST to find all function and class definitions
	build_cfgs_for_defs(&result, module.body, bind_result, file_path, allocator)

	// Build DFG (reaching definitions) for each scope
	for &cfg in result.cfgs {
		dfg := collect_definitions(&cfg, bind_result, allocator)
		compute_gen_kill(&dfg, &cfg)
		compute_reaching(&dfg, &cfg, allocator)
		result.dfgs[cfg.scope_id] = dfg

		// Constant propagation over this scope's DFG
		cm := propagate_constants(&dfg, &cfg, bind_result, module, allocator)
		result.const_maps[cfg.scope_id] = cm
	}

	// Extract narrowing guards from all CFGs
	result.guards = extract_guards(result.cfgs[:], bind_result, allocator)

	// Check for F002 (missing return) in function CFGs
	for &cfg in result.cfgs {
		scope := binder.result_get_scope(bind_result, cfg.scope_id)
		if scope == nil { continue }
		if scope.kind != .Function { continue }

		has_return_ann := false
		has_any_return := false
		returns_none := false
		is_stub := false

		// Check if function has return annotation or explicit returns
		check_function_returns(module.body, scope, &has_return_ann, &has_any_return, &returns_none, &is_stub)

		// Only flag F002 for functions with non-None return annotations
		// Skip stub bodies (Protocol methods, abstract methods with ... or pass)
		if !has_return_ann || returns_none || is_stub { continue }

		check_missing_return(&cfg, cfg.scope_name, has_return_ann, has_any_return, file_path, scope.loc, &result.diagnostics)
	}

	return result
}

// ==================== Recursive CFG Building ====================

build_cfgs_for_defs :: proc(result: ^Flow_Result, stmts: []parser.Stmt, bind_result: ^binder.Bind_Result, file_path: string, allocator: mem.Allocator) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			scope_id := find_scope_for_def(bind_result, s.name, s.loc, .Function)
			if scope_id != binder.INVALID_SCOPE {
				cfg := build_cfg_for_stmts(
					s.body, scope_id, s.name,
					bind_result, file_path, &result.diagnostics, allocator,
				)
				compute_reachability(&cfg)
				idx := len(result.cfgs)
				append(&result.cfgs, cfg)
				result.scope_to_cfg[scope_id] = idx
			}
			// Recurse into body for nested definitions
			build_cfgs_for_defs(result, s.body, bind_result, file_path, allocator)

		case ^parser.Async_Func_Def:
			scope_id := find_scope_for_def(bind_result, s.name, s.loc, .Function)
			if scope_id != binder.INVALID_SCOPE {
				cfg := build_cfg_for_stmts(
					s.body, scope_id, s.name,
					bind_result, file_path, &result.diagnostics, allocator,
				)
				compute_reachability(&cfg)
				idx := len(result.cfgs)
				append(&result.cfgs, cfg)
				result.scope_to_cfg[scope_id] = idx
			}
			build_cfgs_for_defs(result, s.body, bind_result, file_path, allocator)

		case ^parser.Class_Def:
			scope_id := find_scope_for_def(bind_result, s.name, s.loc, .Class)
			if scope_id != binder.INVALID_SCOPE {
				cfg := build_cfg_for_stmts(
					s.body, scope_id, s.name,
					bind_result, file_path, &result.diagnostics, allocator,
				)
				compute_reachability(&cfg)
				idx := len(result.cfgs)
				append(&result.cfgs, cfg)
				result.scope_to_cfg[scope_id] = idx
			}
			build_cfgs_for_defs(result, s.body, bind_result, file_path, allocator)

		// Recurse into branching statements to find nested defs
		case ^parser.If_Stmt:
			build_cfgs_for_defs(result, s.body, bind_result, file_path, allocator)
			build_cfgs_for_defs(result, s.orelse, bind_result, file_path, allocator)
		case ^parser.While_Stmt:
			build_cfgs_for_defs(result, s.body, bind_result, file_path, allocator)
			build_cfgs_for_defs(result, s.orelse, bind_result, file_path, allocator)
		case ^parser.For_Stmt:
			build_cfgs_for_defs(result, s.body, bind_result, file_path, allocator)
			build_cfgs_for_defs(result, s.orelse, bind_result, file_path, allocator)
		case ^parser.Async_For:
			build_cfgs_for_defs(result, s.body, bind_result, file_path, allocator)
			build_cfgs_for_defs(result, s.orelse, bind_result, file_path, allocator)
		case ^parser.With_Stmt:
			build_cfgs_for_defs(result, s.body, bind_result, file_path, allocator)
		case ^parser.Async_With:
			build_cfgs_for_defs(result, s.body, bind_result, file_path, allocator)
		case ^parser.Try_Stmt:
			build_cfgs_for_defs(result, s.body, bind_result, file_path, allocator)
			for handler in s.handlers {
				build_cfgs_for_defs(result, handler.body, bind_result, file_path, allocator)
			}
			build_cfgs_for_defs(result, s.orelse, bind_result, file_path, allocator)
			build_cfgs_for_defs(result, s.finalbody, bind_result, file_path, allocator)
		case ^parser.Try_Star:
			build_cfgs_for_defs(result, s.body, bind_result, file_path, allocator)
			for handler in s.handlers {
				build_cfgs_for_defs(result, handler.body, bind_result, file_path, allocator)
			}
			build_cfgs_for_defs(result, s.orelse, bind_result, file_path, allocator)
			build_cfgs_for_defs(result, s.finalbody, bind_result, file_path, allocator)
		case ^parser.Match_Stmt:
			for mc in s.cases {
				build_cfgs_for_defs(result, mc.body, bind_result, file_path, allocator)
			}

		// Scan expressions for lambda definitions
		case ^parser.Assign:
			if s.value != nil {
				build_cfgs_for_lambdas(result, s.value, bind_result, file_path, allocator)
			}
		case ^parser.Ann_Assign:
			if s.value != nil {
				build_cfgs_for_lambdas(result, s.value, bind_result, file_path, allocator)
			}
		case ^parser.Expr_Stmt:
			if s.value != nil {
				build_cfgs_for_lambdas(result, s.value, bind_result, file_path, allocator)
			}
		case ^parser.Return_Stmt:
			if s.value != nil {
				build_cfgs_for_lambdas(result, s.value, bind_result, file_path, allocator)
			}
		}
	}
}

// Find Lambda_Expr in expression trees and build CFGs for them.
// Lambda body (single expr) is wrapped in a synthetic Return_Stmt.
build_cfgs_for_lambdas :: proc(
	result: ^Flow_Result,
	expr: parser.Expr,
	bind_result: ^binder.Bind_Result,
	file_path: string,
	allocator: mem.Allocator,
) {
	if expr == nil { return }
	#partial switch e in expr {
	case ^parser.Lambda_Expr:
		scope_id := find_scope_for_def(bind_result, "<lambda>", e.loc, .Lambda)
		if scope_id != binder.INVALID_SCOPE {
			// Wrap lambda body expression in a synthetic Return_Stmt
			// Must be arena-allocated — stack allocation would dangle after this proc returns
			synthetic_return := new(parser.Return_Stmt, allocator)
			synthetic_return.base = parser.Node_Base{loc = e.loc}
			synthetic_return.value = e.body
			synthetic_stmts := [1]parser.Stmt{synthetic_return}
			cfg := build_cfg_for_stmts(
				synthetic_stmts[:], scope_id, "<lambda>",
				bind_result, file_path, &result.diagnostics, allocator,
			)
			compute_reachability(&cfg)
			idx := len(result.cfgs)
			append(&result.cfgs, cfg)
			result.scope_to_cfg[scope_id] = idx
		}
	case ^parser.Call_Expr:
		build_cfgs_for_lambdas(result, e.func, bind_result, file_path, allocator)
		for arg in e.args { build_cfgs_for_lambdas(result, arg, bind_result, file_path, allocator) }
		for &kw in e.keywords { build_cfgs_for_lambdas(result, kw.value, bind_result, file_path, allocator) }
	case ^parser.If_Expr:
		build_cfgs_for_lambdas(result, e.body, bind_result, file_path, allocator)
		build_cfgs_for_lambdas(result, e.test, bind_result, file_path, allocator)
		build_cfgs_for_lambdas(result, e.orelse, bind_result, file_path, allocator)
	case ^parser.Tuple_Expr:
		for el in e.elts { build_cfgs_for_lambdas(result, el, bind_result, file_path, allocator) }
	case ^parser.List_Expr:
		for el in e.elts { build_cfgs_for_lambdas(result, el, bind_result, file_path, allocator) }
	case ^parser.Dict_Expr:
		for v in e.values { build_cfgs_for_lambdas(result, v, bind_result, file_path, allocator) }
	}
}

// ==================== Helpers ====================

find_scope_for_def :: proc(bind_result: ^binder.Bind_Result, name: string, loc: parser.Src_Loc, kind: binder.Scope_Kind) -> binder.Scope_ID {
	for &scope in bind_result.scopes {
		if scope.name == name && scope.kind == kind && scope.loc.line == loc.line && scope.loc.col == loc.col {
			return scope.id
		}
	}
	return binder.INVALID_SCOPE
}

body_is_stub :: proc(stmts: []parser.Stmt) -> bool {
	// A stub body is exactly one statement: either `...` (Ellipsis) or `pass`
	if len(stmts) != 1 { return false }
	#partial switch s in stmts[0] {
	case ^parser.Expr_Stmt:
		// Check for `...` (Ellipsis constant)
		c, ok := s.value.(^parser.Constant_Expr)
		if ok {
			_, is_ellipsis := c.value.(parser.Const_Ellipsis)
			return is_ellipsis
		}
	case ^parser.Pass_Stmt:
		return true
	}
	return false
}

returns_is_none :: proc(returns: parser.Expr) -> bool {
	if returns == nil { return false }
	c, ok := returns.(^parser.Constant_Expr)
	if !ok { return false }
	_, is_none := c.value.(parser.Const_None)
	return is_none
}

check_function_returns :: proc(stmts: []parser.Stmt, target_scope: ^binder.Scope, has_return_ann: ^bool, has_any_return: ^bool, returns_none: ^bool, is_stub: ^bool) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			if s.name == target_scope.name && s.loc.line == target_scope.loc.line {
				has_return_ann^ = s.returns != nil
				returns_none^ = returns_is_none(s.returns)
				is_stub^ = body_is_stub(s.body)
				scan_for_returns(s.body, has_any_return)
				return
			}
			// Recurse to find nested
			check_function_returns(s.body, target_scope, has_return_ann, has_any_return, returns_none, is_stub)

		case ^parser.Async_Func_Def:
			if s.name == target_scope.name && s.loc.line == target_scope.loc.line {
				has_return_ann^ = s.returns != nil
				returns_none^ = returns_is_none(s.returns)
				is_stub^ = body_is_stub(s.body)
				scan_for_returns(s.body, has_any_return)
				return
			}
			check_function_returns(s.body, target_scope, has_return_ann, has_any_return, returns_none, is_stub)

		case ^parser.Class_Def:
			check_function_returns(s.body, target_scope, has_return_ann, has_any_return, returns_none, is_stub)
		case ^parser.If_Stmt:
			check_function_returns(s.body, target_scope, has_return_ann, has_any_return, returns_none, is_stub)
			check_function_returns(s.orelse, target_scope, has_return_ann, has_any_return, returns_none, is_stub)
		case ^parser.While_Stmt:
			check_function_returns(s.body, target_scope, has_return_ann, has_any_return, returns_none, is_stub)
		case ^parser.For_Stmt:
			check_function_returns(s.body, target_scope, has_return_ann, has_any_return, returns_none, is_stub)
		case ^parser.Try_Stmt:
			check_function_returns(s.body, target_scope, has_return_ann, has_any_return, returns_none, is_stub)
			for handler in s.handlers {
				check_function_returns(handler.body, target_scope, has_return_ann, has_any_return, returns_none, is_stub)
			}
			check_function_returns(s.orelse, target_scope, has_return_ann, has_any_return, returns_none, is_stub)
			check_function_returns(s.finalbody, target_scope, has_return_ann, has_any_return, returns_none, is_stub)
		case ^parser.With_Stmt:
			check_function_returns(s.body, target_scope, has_return_ann, has_any_return, returns_none, is_stub)
		}
	}
}

scan_for_returns :: proc(stmts: []parser.Stmt, has_any_return: ^bool) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Return_Stmt:
			has_any_return^ = true
			return
		case ^parser.If_Stmt:
			scan_for_returns(s.body, has_any_return)
			scan_for_returns(s.orelse, has_any_return)
		case ^parser.While_Stmt:
			scan_for_returns(s.body, has_any_return)
		case ^parser.For_Stmt:
			scan_for_returns(s.body, has_any_return)
		case ^parser.Try_Stmt:
			scan_for_returns(s.body, has_any_return)
			for handler in s.handlers {
				scan_for_returns(handler.body, has_any_return)
			}
			scan_for_returns(s.orelse, has_any_return)
			scan_for_returns(s.finalbody, has_any_return)
		case ^parser.With_Stmt:
			scan_for_returns(s.body, has_any_return)
		}
		if has_any_return^ { return }
	}
}

get_cfg_for_scope :: proc(result: ^Flow_Result, scope_id: binder.Scope_ID) -> ^CFG {
	if idx, ok := result.scope_to_cfg[scope_id]; ok {
		if idx >= 0 && idx < len(result.cfgs) {
			return &result.cfgs[idx]
		}
	}
	return nil
}
