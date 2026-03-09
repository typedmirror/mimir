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
	diagnostics:  [dynamic]core.Diagnostic,
}

// ==================== Entry Point ====================

analyze :: proc(module: ^parser.Module, bind_result: ^binder.Bind_Result, file_path: string, allocator: mem.Allocator) -> Flow_Result {
	result: Flow_Result
	result.cfgs = make([dynamic]CFG, 0, 16, allocator)
	result.scope_to_cfg = make(map[binder.Scope_ID]int, 16, allocator)
	result.guards = make([dynamic]Guard, 0, 16, allocator)
	result.diagnostics = make([dynamic]core.Diagnostic, 0, 8, allocator)

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

	// Compute DFG for each CFG (reaching definitions)
	for &cfg in result.cfgs {
		dfg := collect_definitions(&cfg, bind_result, allocator)
		compute_gen_kill(&dfg, &cfg)
		compute_reaching(&dfg, &cfg, allocator)
		// DFG is attached to the flow result implicitly through the CFG scope mapping
		// Phase 4 will query via defs_reaching_use
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

		// Check if function has return annotation or explicit returns
		check_function_returns(module.body, scope, &has_return_ann, &has_any_return, &returns_none)

		// Only flag F002 for functions with non-None return annotations
		if !has_return_ann || returns_none { continue }

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
		}
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

returns_is_none :: proc(returns: parser.Expr) -> bool {
	if returns == nil { return false }
	c, ok := returns.(^parser.Constant_Expr)
	if !ok { return false }
	_, is_none := c.value.(parser.Const_None)
	return is_none
}

check_function_returns :: proc(stmts: []parser.Stmt, target_scope: ^binder.Scope, has_return_ann: ^bool, has_any_return: ^bool, returns_none: ^bool) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			if s.name == target_scope.name && s.loc.line == target_scope.loc.line {
				has_return_ann^ = s.returns != nil
				returns_none^ = returns_is_none(s.returns)
				scan_for_returns(s.body, has_any_return)
				return
			}
			// Recurse to find nested
			check_function_returns(s.body, target_scope, has_return_ann, has_any_return, returns_none)

		case ^parser.Async_Func_Def:
			if s.name == target_scope.name && s.loc.line == target_scope.loc.line {
				has_return_ann^ = s.returns != nil
				returns_none^ = returns_is_none(s.returns)
				scan_for_returns(s.body, has_any_return)
				return
			}
			check_function_returns(s.body, target_scope, has_return_ann, has_any_return, returns_none)

		case ^parser.Class_Def:
			check_function_returns(s.body, target_scope, has_return_ann, has_any_return, returns_none)
		case ^parser.If_Stmt:
			check_function_returns(s.body, target_scope, has_return_ann, has_any_return, returns_none)
			check_function_returns(s.orelse, target_scope, has_return_ann, has_any_return, returns_none)
		case ^parser.While_Stmt:
			check_function_returns(s.body, target_scope, has_return_ann, has_any_return, returns_none)
		case ^parser.For_Stmt:
			check_function_returns(s.body, target_scope, has_return_ann, has_any_return, returns_none)
		case ^parser.Try_Stmt:
			check_function_returns(s.body, target_scope, has_return_ann, has_any_return, returns_none)
			for handler in s.handlers {
				check_function_returns(handler.body, target_scope, has_return_ann, has_any_return, returns_none)
			}
			check_function_returns(s.orelse, target_scope, has_return_ann, has_any_return, returns_none)
			check_function_returns(s.finalbody, target_scope, has_return_ann, has_any_return, returns_none)
		case ^parser.With_Stmt:
			check_function_returns(s.body, target_scope, has_return_ann, has_any_return, returns_none)
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
