package checker

import "core:mem"
import "core:fmt"

import parser "mimir:parser"
import binder "mimir:binder"
import flow   "mimir:flow"
import core   "mimir:core"

// ==================== Check Result ====================

Check_Result :: struct {
	registry:     Type_Registry,
	symbol_types: map[binder.Symbol_ID]Type_ID,
	expr_types:   map[rawptr]Type_ID,
	diagnostics:  [dynamic]core.Diagnostic,
}

// ==================== Entry Point ====================

check :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	flow_result: ^flow.Flow_Result,
	file_path: string,
	allocator: mem.Allocator,
) -> Check_Result {
	result: Check_Result
	result.registry = init_registry(allocator)
	result.symbol_types = make(map[binder.Symbol_ID]Type_ID, 128, allocator)
	result.expr_types = make(map[rawptr]Type_ID, 256, allocator)
	result.diagnostics = make([dynamic]core.Diagnostic, 0, 32, allocator)

	builtins := init_builtins(&result.registry)

	// Build scope→return type map by scanning AST
	return_type_map := make(map[binder.Scope_ID]Type_ID, 16, allocator)
	collect_func_return_types(module.body, bind_result, &result.registry, &builtins, &return_type_map)

	// Process each scope's CFG
	for &cfg in flow_result.cfgs {
		declared_return := TYPE_UNKNOWN
		if ret, ok := return_type_map[cfg.scope_id]; ok {
			declared_return = ret
		}
		check_scope(
			&cfg,
			bind_result,
			flow_result,
			&result,
			&builtins,
			file_path,
			declared_return,
		)
	}

	return result
}

// ==================== Scope Checking (CFG Walk) ====================

check_scope :: proc(
	cfg: ^flow.CFG,
	bind_result: ^binder.Bind_Result,
	flow_result: ^flow.Flow_Result,
	result: ^Check_Result,
	builtins: ^Builtin_Names,
	file_path: string,
	declared_return: Type_ID,
) {
	n_blocks := len(cfg.blocks)
	if n_blocks == 0 { return }

	// Create per-block type environments
	envs := make([]Type_Env, n_blocks, result.registry.allocator)
	for i in 0..<n_blocks {
		envs[i].types = make(map[binder.Symbol_ID]Type_ID, 16, result.registry.allocator)
	}

	// Initialize entry block with parameter types from scope
	entry_idx := int(cfg.entry)
	if entry_idx < n_blocks {
		scope := binder.result_get_scope(bind_result, cfg.scope_id)
		if scope != nil && (scope.kind == .Function || scope.kind == .Lambda) {
			init_param_types(scope, bind_result, &envs[entry_idx], &result.registry, builtins)
		}
	}

	// Collect return types for function return checking
	return_types := make([dynamic]Type_ID, 0, 8, result.registry.allocator)

	// BFS walk from entry
	visited := make([]bool, n_blocks, result.registry.allocator)
	queue := make([dynamic]flow.Block_ID, 0, n_blocks, result.registry.allocator)
	append(&queue, cfg.entry)

	for len(queue) > 0 {
		block_id := queue[0]
		ordered_remove(&queue, 0)
		idx := int(block_id)

		if idx >= n_blocks { continue }
		if visited[idx] { continue }
		visited[idx] = true

		block := flow.get_block(cfg, block_id)
		if block == nil || !block.is_reachable { continue }

		// Merge environments from predecessors
		env := merge_envs(block, envs[:], cfg, &result.registry)

		// Apply narrowing guards
		apply_guards(&env, block_id, flow_result.guards[:], &result.registry, bind_result, builtins)

		// Build inference context
		ctx := Infer_Context{
			env         = &env,
			reg         = &result.registry,
			bind_result = bind_result,
			builtins    = builtins,
			expr_types  = &result.expr_types,
			diagnostics = &result.diagnostics,
			file_path   = file_path,
		}

		// Process each statement in the block
		for stmt in block.stmts {
			check_stmt(stmt, &ctx, &return_types, declared_return)
		}

		// Store environment for successors
		envs[idx] = env

		// Enqueue successors
		for succ in block.succs {
			succ_idx := int(succ)
			if succ_idx < n_blocks && !visited[succ_idx] {
				append(&queue, succ)
			}
		}
	}

	// Return type checking is done inline in check_stmt for Return_Stmt

	// Store final symbol types
	for i in 0..<n_blocks {
		if visited[i] {
			for sym_id, type_id in envs[i].types {
				result.symbol_types[sym_id] = type_id
			}
		}
	}
}

// ==================== Statement Checking ====================

check_stmt :: proc(
	stmt: parser.Stmt,
	ctx: ^Infer_Context,
	return_types: ^[dynamic]Type_ID,
	declared_return: Type_ID,
) {
	switch s in stmt {
	case ^parser.Assign:
		rhs_type := infer_expr(s.value, ctx)
		for target in s.targets {
			assign_target(target, rhs_type, ctx)
		}

	case ^parser.Ann_Assign:
		declared := resolve_annotation(s.annotation, ctx.reg, ctx.bind_result, ctx.builtins)
		// Set the declared type on the symbol
		set_target_type(s.target, declared, ctx)

		if s.value != nil {
			rhs_type := infer_expr(s.value, ctx)
			if declared != TYPE_UNKNOWN && rhs_type != TYPE_UNKNOWN &&
			   rhs_type != TYPE_ANY && declared != TYPE_ANY {
				if !is_assignable(ctx.reg, rhs_type, declared) {
					emit_diagnostic(ctx, s.loc, "T001", .Error,
						"Incompatible types in assignment",
						fmt_type_mismatch(rhs_type, declared, ctx.reg),
						"Change the value or the annotation")
				}
			}
		}

	case ^parser.Return_Stmt:
		if s.value != nil {
			ret_type := infer_expr(s.value, ctx)
			append(return_types, ret_type)

			if declared_return != TYPE_UNKNOWN && declared_return != TYPE_ANY &&
			   ret_type != TYPE_UNKNOWN && ret_type != TYPE_ANY {
				if !is_assignable(ctx.reg, ret_type, declared_return) {
					emit_diagnostic(ctx, s.loc, "T003", .Error,
						"Incompatible return value type",
						fmt_type_mismatch(ret_type, declared_return, ctx.reg),
						"Change the return value or the return annotation")
				}
			}
		} else {
			append(return_types, TYPE_NONE)
		}

	case ^parser.Func_Def:
		func_type := build_func_type(s, ctx)
		set_name_type(s.name, func_type, ctx)

	case ^parser.Async_Func_Def:
		func_type := build_async_func_type(s, ctx)
		set_name_type(s.name, func_type, ctx)

	case ^parser.Class_Def:
		class_type := build_class_type(s, ctx)
		set_name_type(s.name, class_type, ctx)

	case ^parser.Aug_Assign:
		lhs_type := infer_expr(s.target, ctx)
		rhs_type := infer_expr(s.value, ctx)
		result_type := infer_binop(s.op, lhs_type, rhs_type, ctx.reg)
		if result_type == TYPE_UNKNOWN && lhs_type != TYPE_UNKNOWN && rhs_type != TYPE_UNKNOWN {
			emit_diagnostic(ctx, s.loc, "T005", .Error,
				"Unsupported operand types",
				fmt_binop_error(s.op, lhs_type, rhs_type, ctx.reg),
				"Check operand types")
		}
		assign_target(s.target, result_type, ctx)

	case ^parser.For_Stmt:
		iter_type := infer_expr(s.iter, ctx)
		elem_type := get_iterator_element_type(iter_type, ctx.reg)
		assign_target(s.target, elem_type, ctx)

	case ^parser.Expr_Stmt:
		infer_expr(s.value, ctx)

	case ^parser.If_Stmt:
		infer_expr(s.test, ctx)

	case ^parser.While_Stmt:
		infer_expr(s.test, ctx)

	case ^parser.Assert_Stmt:
		infer_expr(s.test, ctx)
		if s.msg != nil {
			infer_expr(s.msg, ctx)
		}

	case ^parser.Raise_Stmt:
		if s.exc != nil {
			infer_expr(s.exc, ctx)
		}

	case ^parser.Delete_Stmt:
		for target in s.targets {
			infer_expr(target, ctx)
		}

	// Statements with no type checking at this phase
	case ^parser.Pass_Stmt:
	case ^parser.Break_Stmt:
	case ^parser.Continue_Stmt:
	case ^parser.Global_Stmt:
	case ^parser.Nonlocal_Stmt:
	case ^parser.Import_Stmt:
	case ^parser.Import_From:
	case ^parser.With_Stmt:
	case ^parser.Async_With:
	case ^parser.Async_For:
	case ^parser.Try_Stmt:
	case ^parser.Try_Star:
	case ^parser.Match_Stmt:
	case ^parser.Type_Alias_Stmt:
	}
}

// ==================== Environment Merging ====================

merge_envs :: proc(
	block: ^flow.Block,
	envs: []Type_Env,
	cfg: ^flow.CFG,
	reg: ^Type_Registry,
) -> Type_Env {
	env: Type_Env
	env.types = make(map[binder.Symbol_ID]Type_ID, 16, reg.allocator)

	pred_count := 0
	for pred_id in block.preds {
		pred_idx := int(pred_id)
		if pred_idx >= len(envs) { continue }
		pred_env := &envs[pred_idx]

		for sym_id, type_id in pred_env.types {
			if existing, ok := env.types[sym_id]; ok {
				if existing != type_id {
					members := [2]Type_ID{existing, type_id}
					env.types[sym_id] = make_union_type(reg, members[:])
				}
			} else {
				env.types[sym_id] = type_id
			}
		}
		pred_count += 1
	}

	return env
}

// ==================== Narrowing Guard Application ====================

apply_guards :: proc(
	env: ^Type_Env,
	block_id: flow.Block_ID,
	guards: []flow.Guard,
	reg: ^Type_Registry,
	bind_result: ^binder.Bind_Result,
	builtins: ^Builtin_Names,
) {
	for &guard in guards {
		if guard.true_block == block_id {
			apply_positive_guard(env, &guard, reg, bind_result, builtins)
		} else if guard.false_block == block_id {
			apply_negative_guard(env, &guard, reg, bind_result, builtins)
		}
	}
}

apply_positive_guard :: proc(
	env: ^Type_Env,
	guard: ^flow.Guard,
	reg: ^Type_Registry,
	bind_result: ^binder.Bind_Result,
	builtins: ^Builtin_Names,
) {
	#partial switch guard.kind {
	case .Is_Instance:
		narrow_type := resolve_annotation(guard.type_expr, reg, bind_result, builtins)
		if narrow_type != TYPE_UNKNOWN {
			env.types[guard.symbol_id] = narrow_type
		}
	case .Is_None:
		env.types[guard.symbol_id] = TYPE_NONE
	case .Is_Not_None:
		current, ok := env.types[guard.symbol_id]
		if ok {
			env.types[guard.symbol_id] = remove_none(reg, current)
		}
	case .Is_Truthy:
		current, ok := env.types[guard.symbol_id]
		if ok {
			env.types[guard.symbol_id] = remove_none(reg, current)
		}
	case .Type_Is:
		narrow_type := resolve_annotation(guard.type_expr, reg, bind_result, builtins)
		if narrow_type != TYPE_UNKNOWN {
			env.types[guard.symbol_id] = narrow_type
		}
	}
}

apply_negative_guard :: proc(
	env: ^Type_Env,
	guard: ^flow.Guard,
	reg: ^Type_Registry,
	bind_result: ^binder.Bind_Result,
	builtins: ^Builtin_Names,
) {
	#partial switch guard.kind {
	case .Is_Instance:
		narrow_type := resolve_annotation(guard.type_expr, reg, bind_result, builtins)
		current, ok := env.types[guard.symbol_id]
		if ok && narrow_type != TYPE_UNKNOWN {
			env.types[guard.symbol_id] = subtract_type(reg, current, narrow_type)
		}
	case .Is_None:
		current, ok := env.types[guard.symbol_id]
		if ok {
			env.types[guard.symbol_id] = remove_none(reg, current)
		}
	case .Is_Not_None:
		env.types[guard.symbol_id] = TYPE_NONE
	case .Is_Truthy:
		// In false branch of truthiness — could be None/False/0/empty
		// Conservative: don't narrow
		break
	}
}

// ==================== Function/Class Type Building ====================

build_func_type :: proc(fd: ^parser.Func_Def, ctx: ^Infer_Context) -> Type_ID {
	params := resolve_params(&fd.args, ctx)

	// Skip 'self' parameter for methods
	actual_params := params
	if len(params) > 0 && params[0].name == "self" {
		actual_params = params[1:]
	}

	ret_type := resolve_annotation(fd.returns, ctx.reg, ctx.bind_result, ctx.builtins)
	return make_callable_type(ctx.reg, actual_params, ret_type)
}

build_async_func_type :: proc(fd: ^parser.Async_Func_Def, ctx: ^Infer_Context) -> Type_ID {
	params := resolve_params(&fd.args, ctx)
	actual_params := params
	if len(params) > 0 && params[0].name == "self" {
		actual_params = params[1:]
	}
	ret_type := resolve_annotation(fd.returns, ctx.reg, ctx.bind_result, ctx.builtins)
	return make_callable_type(ctx.reg, actual_params, ret_type)
}

build_class_type :: proc(cd: ^parser.Class_Def, ctx: ^Infer_Context) -> Type_ID {
	// Find the scope for this class in binder
	scope_id := find_scope_for_def(cd.name, cd.loc, ctx.bind_result, .Class)

	// Resolve base classes
	bases := make([]Type_ID, len(cd.bases), ctx.reg.allocator)
	for base, i in cd.bases {
		bases[i] = infer_expr(base, ctx)
	}

	// Build attrs from class body
	attrs := make(map[string]Type_ID, 16, ctx.reg.allocator)

	// Scan class body for method and attribute definitions
	for stmt in cd.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			ft := build_func_type(s, ctx)
			attrs[s.name] = ft

			// Scan __init__ for self.x = ... attribute assignments
			if s.name == "__init__" {
				scan_init_attrs(s, ctx, &attrs)
			}

		case ^parser.Ann_Assign:
			declared := resolve_annotation(s.annotation, ctx.reg, ctx.bind_result, ctx.builtins)
			if name_expr, ok := s.target.(^parser.Name_Expr); ok {
				attrs[name_expr.id] = declared
			}

		case ^parser.Assign:
			if s.value != nil {
				val_type := infer_expr(s.value, ctx)
				for target in s.targets {
					if name_expr, ok := target.(^parser.Name_Expr); ok {
						attrs[name_expr.id] = val_type
					}
				}
			}
		}
	}

	sym_id := find_symbol_for_name(cd.name, cd.loc, ctx.bind_result)
	class_type_id := register_type(ctx.reg, Class_Type{
		name      = cd.name,
		symbol_id = sym_id,
		scope_id  = scope_id,
		bases     = bases,
		attrs     = attrs,
	})

	return class_type_id
}

// Scan __init__ body for self.attr = value patterns
scan_init_attrs :: proc(fd: ^parser.Func_Def, ctx: ^Infer_Context, attrs: ^map[string]Type_ID) {
	for stmt in fd.body {
		#partial switch s in stmt {
		case ^parser.Assign:
			for target in s.targets {
				if attr, ok := target.(^parser.Attribute_Expr); ok {
					if self_name, ok2 := attr.value.(^parser.Name_Expr); ok2 {
						if self_name.id == "self" {
							// Check if there's a type annotation from parameter
							val_type := TYPE_UNKNOWN
							if s.value != nil {
								// Try to infer from RHS
								// Simple case: self.x = x where x is a parameter
								if name, ok3 := s.value.(^parser.Name_Expr); ok3 {
									// Look up parameter type
									for arg in fd.args.args {
										if arg.arg == name.id {
											val_type = resolve_annotation(
												arg.annotation, ctx.reg, ctx.bind_result, ctx.builtins)
											break
										}
									}
								}
							}
							attrs[attr.attr] = val_type
						}
					}
				}
			}

		case ^parser.Ann_Assign:
			if attr, ok := s.target.(^parser.Attribute_Expr); ok {
				if self_name, ok2 := attr.value.(^parser.Name_Expr); ok2 {
					if self_name.id == "self" {
						declared := resolve_annotation(s.annotation, ctx.reg, ctx.bind_result, ctx.builtins)
						attrs[attr.attr] = declared
					}
				}
			}
		}
	}
}

// ==================== Assignment Helpers ====================

assign_target :: proc(target: parser.Expr, type_id: Type_ID, ctx: ^Infer_Context) {
	#partial switch e in target {
	case ^parser.Name_Expr:
		if sym_id, ok := binder.get_ref(ctx.bind_result, rawptr(e)); ok {
			ctx.env.types[sym_id] = type_id
		}
	case ^parser.Tuple_Expr:
		// Tuple unpacking
		for elt, i in e.elts {
			elem_type := TYPE_UNKNOWN
			t := get_type(ctx.reg, type_id)
			#partial switch info in t.info {
			case Tuple_Type:
				if i < len(info.elements) {
					elem_type = info.elements[i]
				}
			case List_Type:
				elem_type = info.element
			}
			assign_target(elt, elem_type, ctx)
		}
	case ^parser.List_Expr:
		// List unpacking (same as tuple)
		for elt, i in e.elts {
			elem_type := TYPE_UNKNOWN
			t := get_type(ctx.reg, type_id)
			#partial switch info in t.info {
			case Tuple_Type:
				if i < len(info.elements) {
					elem_type = info.elements[i]
				}
			case List_Type:
				elem_type = info.element
			}
			assign_target(elt, elem_type, ctx)
		}
	case ^parser.Starred_Expr:
		// *x in unpacking — gets a list
		assign_target(e.value, make_list_type(ctx.reg, TYPE_UNKNOWN), ctx)
	}
}

set_target_type :: proc(target: parser.Expr, type_id: Type_ID, ctx: ^Infer_Context) {
	#partial switch e in target {
	case ^parser.Name_Expr:
		if sym_id, ok := binder.get_ref(ctx.bind_result, rawptr(e)); ok {
			ctx.env.types[sym_id] = type_id
		}
	}
}

set_name_type :: proc(name: string, type_id: Type_ID, ctx: ^Infer_Context) {
	// Find symbol for this name in current scope
	for sym_id, sym_type in ctx.env.types {
		sym := binder.result_get_symbol(ctx.bind_result, sym_id)
		if sym != nil && sym.name == name {
			ctx.env.types[sym_id] = type_id
			return
		}
	}
	// If not in env yet, search in bind_result
	for &sym in ctx.bind_result.symbols {
		if sym.name == name {
			ctx.env.types[sym.id] = type_id
			return
		}
	}
}

// ==================== Return Type Checking ====================

check_return_types :: proc(
	return_types: []Type_ID,
	declared_return: Type_ID,
	func_def: ^parser.Func_Def,
	result: ^Check_Result,
	file_path: string,
) {
	// Already checked inline during stmt processing (T003)
	// This is for additional cross-block analysis if needed
}

// ==================== AST Scanning for Return Types ====================

collect_func_return_types :: proc(
	stmts: []parser.Stmt,
	bind_result: ^binder.Bind_Result,
	reg: ^Type_Registry,
	builtins: ^Builtin_Names,
	out: ^map[binder.Scope_ID]Type_ID,
) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			ret := resolve_annotation(s.returns, reg, bind_result, builtins)
			scope_id := find_scope_for_def(s.name, s.loc, bind_result, .Function)
			if scope_id != binder.INVALID_SCOPE {
				out[scope_id] = ret
			}
			// Recurse into function body for nested defs
			collect_func_return_types(s.body, bind_result, reg, builtins, out)

		case ^parser.Async_Func_Def:
			ret := resolve_annotation(s.returns, reg, bind_result, builtins)
			scope_id := find_scope_for_def(s.name, s.loc, bind_result, .Function)
			if scope_id != binder.INVALID_SCOPE {
				out[scope_id] = ret
			}
			collect_func_return_types(s.body, bind_result, reg, builtins, out)

		case ^parser.Class_Def:
			collect_func_return_types(s.body, bind_result, reg, builtins, out)

		case ^parser.If_Stmt:
			collect_func_return_types(s.body, bind_result, reg, builtins, out)
			collect_func_return_types(s.orelse, bind_result, reg, builtins, out)

		case ^parser.For_Stmt:
			collect_func_return_types(s.body, bind_result, reg, builtins, out)
			collect_func_return_types(s.orelse, bind_result, reg, builtins, out)

		case ^parser.While_Stmt:
			collect_func_return_types(s.body, bind_result, reg, builtins, out)
			collect_func_return_types(s.orelse, bind_result, reg, builtins, out)

		case ^parser.With_Stmt:
			collect_func_return_types(s.body, bind_result, reg, builtins, out)

		case ^parser.Try_Stmt:
			collect_func_return_types(s.body, bind_result, reg, builtins, out)
			collect_func_return_types(s.finalbody, bind_result, reg, builtins, out)
			collect_func_return_types(s.orelse, bind_result, reg, builtins, out)
		}
	}
}

// ==================== Scope/Symbol Lookup Helpers ====================

find_scope_for_def :: proc(
	name: string,
	loc: parser.Src_Loc,
	bind_result: ^binder.Bind_Result,
	kind: binder.Scope_Kind,
) -> binder.Scope_ID {
	for &scope in bind_result.scopes {
		if scope.name == name && scope.kind == kind {
			if scope.loc.line == loc.line && scope.loc.col == loc.col {
				return scope.id
			}
		}
	}
	// Fallback: match by name only
	for &scope in bind_result.scopes {
		if scope.name == name && scope.kind == kind {
			return scope.id
		}
	}
	return binder.INVALID_SCOPE
}

find_symbol_for_name :: proc(
	name: string,
	loc: parser.Src_Loc,
	bind_result: ^binder.Bind_Result,
) -> binder.Symbol_ID {
	for &sym in bind_result.symbols {
		if sym.name == name && sym.def_loc.line == loc.line {
			return sym.id
		}
	}
	for &sym in bind_result.symbols {
		if sym.name == name {
			return sym.id
		}
	}
	return binder.INVALID_SYMBOL
}

get_func_def_for_scope :: proc(
	scope_id: binder.Scope_ID,
	bind_result: ^binder.Bind_Result,
	flow_result: ^flow.Flow_Result,
) -> ^parser.Func_Def {
	// We don't have direct scope→AST mapping, so we skip this for now.
	// Return type checking happens inline in check_stmt for Return_Stmt.
	return nil
}

init_param_types :: proc(
	scope: ^binder.Scope,
	bind_result: ^binder.Bind_Result,
	env: ^Type_Env,
	reg: ^Type_Registry,
	builtins: ^Builtin_Names,
) {
	// Set parameter symbols to their annotated types or UNKNOWN
	for _, sym_id in scope.symbols {
		sym := binder.result_get_symbol(bind_result, sym_id)
		if sym == nil { continue }
		if .Is_Param in sym.flags {
			// Parameter starts as UNKNOWN; annotation-based type comes from
			// the function def processing which sets the callable type
			env.types[sym_id] = TYPE_UNKNOWN
		}
	}
}

// ==================== Public Query API ====================

get_symbol_type :: proc(result: ^Check_Result, sym_id: binder.Symbol_ID) -> Type_ID {
	if t, ok := result.symbol_types[sym_id]; ok {
		return t
	}
	return TYPE_UNKNOWN
}

get_expr_type :: proc(result: ^Check_Result, expr: rawptr) -> Type_ID {
	if t, ok := result.expr_types[expr]; ok {
		return t
	}
	return TYPE_UNKNOWN
}
