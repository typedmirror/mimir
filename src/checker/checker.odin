package checker

import "core:mem"

import parser "mimir:parser"
import binder "mimir:binder"
import flow   "mimir:flow"
import core   "mimir:core"

// ==================== Check Result ====================

Check_Result :: struct {
	registry:        Type_Registry,
	symbol_types:    map[binder.Symbol_ID]Type_ID,
	expr_types:      map[rawptr]Type_ID,
	diagnostics:     [dynamic]core.Diagnostic,
	inferred_returns: map[binder.Scope_ID]Type_ID, // Body-inferred return types for unannotated functions
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
	result.inferred_returns = make(map[binder.Scope_ID]Type_ID, 16, allocator)

	builtins := init_builtins(&result.registry)

	// Initialize virtual module registry (mimir.* ecosystem stubs)
	vreg := init_virtual_registry(&result.registry)

	// Initialize method table once (shared across all check_scope calls)
	mt := init_method_table(&result.registry)

	// Initialize shape registry for mimir.array shape analysis
	shape_reg := init_shape_registry(allocator)

	// Resolve virtual imports (mimir.array, etc.) for single-file mode
	virtual_imports := resolve_virtual_imports(&vreg, bind_result, &result.registry, &shape_reg)

	// Pre-register all classes so return type annotations can reference them
	pre_register_classes(module.body, bind_result, &result.registry)

	// Build scope→return type map and scope→args map by scanning AST
	return_type_map := make(map[binder.Scope_ID]Type_ID, 16, allocator)
	func_args_map := make(map[binder.Scope_ID]^parser.Arguments, 16, allocator)
	collect_func_return_types(module.body, bind_result, &result.registry, &builtins, &return_type_map)
	collect_func_args(module.body, bind_result, &func_args_map)

	// Use virtual imports if present
	virtual_import_ptr: ^map[binder.Symbol_ID]Type_ID = nil
	if len(virtual_imports) > 0 {
		virtual_import_ptr = &virtual_imports
	}

	// Build shape_reg pointer (nil if no shape semantics registered)
	shape_reg_ptr: ^Shape_Registry = nil
	if len(shape_reg.semantics) > 0 {
		shape_reg_ptr = &shape_reg
	}

	// Process each scope's CFG
	for &cfg in flow_result.cfgs {
		declared_return := TYPE_UNKNOWN
		if ret, ok := return_type_map[cfg.scope_id]; ok {
			declared_return = ret
		}
		// Get const_map for this scope
		cm: ^flow.Const_Map = nil
		if scope_cm, ok := &flow_result.const_maps[cfg.scope_id]; ok {
			cm = scope_cm
		}
		check_scope(
			&cfg,
			bind_result,
			flow_result,
			result    = &result,
			builtins  = &builtins,
			file_path = file_path,
			declared_return = declared_return,
			func_args_map = &func_args_map,
			import_types = virtual_import_ptr,
			method_table = &mt,
			shape_reg = shape_reg_ptr,
			const_map = cm,
		)
	}

	// Post-check: backfill inferred return types into Callable_Types
	backfill_inferred_returns(&result, bind_result)

	// Cross-function fixpoint: if returns were inferred, re-check FUNCTION scopes
	// that may reference updated callable types. Skip module scope — re-running it
	// would rebuild callable types from annotations, overwriting backfilled returns.
	if len(result.inferred_returns) > 0 {
		for &cfg in flow_result.cfgs {
			scope := binder.result_get_scope(bind_result, cfg.scope_id)
			if scope == nil { continue }
			// Only re-check function/lambda scopes, not module/class
			if scope.kind != .Function && scope.kind != .Lambda { continue }

			declared_return := TYPE_UNKNOWN
			if ret, ok := return_type_map[cfg.scope_id]; ok {
				declared_return = ret
			}
			// Skip functions with explicit return annotations — they don't benefit
			if declared_return != TYPE_UNKNOWN { continue }

			fixpoint_cm: ^flow.Const_Map = nil
			if scope_cm, ok := &flow_result.const_maps[cfg.scope_id]; ok {
				fixpoint_cm = scope_cm
			}
			check_scope(
				&cfg,
				bind_result,
				flow_result,
				result    = &result,
				builtins  = &builtins,
				file_path = file_path,
				declared_return = declared_return,
				func_args_map = &func_args_map,
				method_table = &mt,
				shape_reg = shape_reg_ptr,
				const_map = fixpoint_cm,
			)
		}

		// Second backfill — pick up any newly inferred returns from the refinement
		backfill_inferred_returns(&result, bind_result)
	}

	// Re-validate module-level assignments against updated return types
	if len(result.inferred_returns) > 0 {
		revalidate_module_calls(module.body, &result, bind_result, &builtins, file_path)
	}

	// Shape analysis pass — validate tensor operation shapes
	if len(shape_reg.semantics) > 0 {
		analyze_shapes(flow_result, &result, bind_result, &shape_reg, file_path, allocator)
	}

	// Route analysis pass — validate mimir.http route decorators
	if len(virtual_imports) > 0 {
		analyze_routes(module, bind_result, &result.registry, &virtual_imports, file_path, &result.diagnostics, allocator)
	}

	// JSON analysis pass — validate JSON serializability
	analyze_json(module, bind_result, &result.registry, &virtual_imports, &result.expr_types, file_path, &result.diagnostics, allocator)

	// DB analysis pass — detect unsafe SQL construction in mimir.db calls
	analyze_db(module, bind_result, &result.registry, &virtual_imports, &result.expr_types, file_path, &result.diagnostics, allocator)

	// Crypt analysis pass — detect cryptographic misuse in mimir.crypt calls
	analyze_crypt(module, bind_result, &result.registry, &virtual_imports, &result.expr_types, file_path, &result.diagnostics, allocator)

	// Regex analysis pass — validate group references
	analyze_regex(module, bind_result, file_path, &result.diagnostics, allocator)

	// D001: unused variable detection (DFG-backed)
	detect_unused_variables(flow_result, bind_result, file_path, &result.diagnostics, allocator)

	return result
}

// ==================== Multi-Module Entry Point ====================

check_with_imports :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	flow_result: ^flow.Flow_Result,
	file_path: string,
	registry: ^Type_Registry,
	builtins: ^Builtin_Names,
	import_types: map[binder.Symbol_ID]Type_ID,
	allocator: mem.Allocator,
) -> Check_Result {
	result: Check_Result
	result.registry = registry^
	result.symbol_types = make(map[binder.Symbol_ID]Type_ID, 128, allocator)
	result.expr_types = make(map[rawptr]Type_ID, 256, allocator)
	result.diagnostics = make([dynamic]core.Diagnostic, 0, 32, allocator)
	result.inferred_returns = make(map[binder.Scope_ID]Type_ID, 16, allocator)

	// Register imported class types in the shared registry's class_types cache
	for sym_id, type_id in import_types {
		t := get_type(registry, type_id)
		#partial switch _ in t.info {
		case Class_Type:
			registry.class_types[sym_id] = type_id
		}
	}

	// Pre-register all classes so return type annotations can reference them
	pre_register_classes(module.body, bind_result, registry)

	return_type_map := make(map[binder.Scope_ID]Type_ID, 16, allocator)
	func_args_map := make(map[binder.Scope_ID]^parser.Arguments, 16, allocator)
	collect_func_return_types(module.body, bind_result, registry, builtins, &return_type_map)
	collect_func_args(module.body, bind_result, &func_args_map)

	local_import_types := import_types
	mt := init_method_table(registry)

	// Shape analysis support for multi-module mode
	shape_reg := init_shape_registry(allocator)
	vreg := init_virtual_registry(registry)
	virtual_imports := resolve_virtual_imports(&vreg, bind_result, registry, &shape_reg)
	shape_reg_ptr: ^Shape_Registry = nil
	if len(shape_reg.semantics) > 0 {
		shape_reg_ptr = &shape_reg
	}

	for &cfg in flow_result.cfgs {
		declared_return := TYPE_UNKNOWN
		if ret, ok := return_type_map[cfg.scope_id]; ok {
			declared_return = ret
		}
		cm: ^flow.Const_Map = nil
		if scope_cm, ok := &flow_result.const_maps[cfg.scope_id]; ok {
			cm = scope_cm
		}
		check_scope(
			&cfg,
			bind_result,
			flow_result,
			result        = &result,
			builtins      = builtins,
			file_path     = file_path,
			declared_return = declared_return,
			func_args_map = &func_args_map,
			reg_override  = registry,
			method_table  = &mt,
			import_types  = &local_import_types,
			shape_reg     = shape_reg_ptr,
			const_map     = cm,
		)
	}

	backfill_inferred_returns(&result, bind_result, registry)

	// Cross-function fixpoint refinement pass
	if len(result.inferred_returns) > 0 {
		for &cfg in flow_result.cfgs {
			scope := binder.result_get_scope(bind_result, cfg.scope_id)
			if scope == nil { continue }
			if scope.kind != .Function && scope.kind != .Lambda { continue }

			declared_return := TYPE_UNKNOWN
			if ret, ok := return_type_map[cfg.scope_id]; ok {
				declared_return = ret
			}
			if declared_return != TYPE_UNKNOWN { continue }

			fp_cm: ^flow.Const_Map = nil
			if scope_cm, ok := &flow_result.const_maps[cfg.scope_id]; ok {
				fp_cm = scope_cm
			}
			check_scope(
				&cfg,
				bind_result,
				flow_result,
				result        = &result,
				builtins      = builtins,
				file_path     = file_path,
				declared_return = declared_return,
				func_args_map = &func_args_map,
				reg_override  = registry,
				import_types  = &local_import_types,
				method_table  = &mt,
				shape_reg     = shape_reg_ptr,
				const_map     = fp_cm,
			)
		}

		backfill_inferred_returns(&result, bind_result, registry)
	}

	if len(result.inferred_returns) > 0 {
		revalidate_module_calls(module.body, &result, bind_result, builtins, file_path, registry)
	}

	// Shape analysis pass
	if len(shape_reg.semantics) > 0 {
		analyze_shapes(flow_result, &result, bind_result, &shape_reg, file_path, allocator)
	}

	// Route analysis pass — validate mimir.http route decorators
	if len(virtual_imports) > 0 {
		analyze_routes(module, bind_result, registry, &virtual_imports, file_path, &result.diagnostics, allocator)
	}

	// JSON analysis pass — validate JSON serializability
	analyze_json(module, bind_result, registry, &virtual_imports, &result.expr_types, file_path, &result.diagnostics, allocator)

	// DB analysis pass — detect unsafe SQL construction in mimir.db calls
	analyze_db(module, bind_result, registry, &virtual_imports, &result.expr_types, file_path, &result.diagnostics, allocator)

	// Crypt analysis pass — detect cryptographic misuse in mimir.crypt calls
	analyze_crypt(module, bind_result, registry, &virtual_imports, &result.expr_types, file_path, &result.diagnostics, allocator)

	// Regex analysis pass — validate group references
	analyze_regex(module, bind_result, file_path, &result.diagnostics, allocator)

	// D001: unused variable detection (DFG-backed)
	detect_unused_variables(flow_result, bind_result, file_path, &result.diagnostics, allocator)

	// Refresh registry snapshot — now includes all types registered during checking
	result.registry = registry^

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
	func_args_map: ^map[binder.Scope_ID]^parser.Arguments,
	reg_override: ^Type_Registry = nil,
	import_types: ^map[binder.Symbol_ID]Type_ID = nil,
	method_table: ^Builtin_Method_Table = nil,
	shape_reg: ^Shape_Registry = nil,
	const_map: ^flow.Const_Map = nil,
) {
	// Use shared registry if provided, otherwise use result's own
	reg := reg_override if reg_override != nil else &result.registry

	n_blocks := len(cfg.blocks)
	if n_blocks == 0 { return }

	// Create per-block type environments
	envs := make([]Type_Env, n_blocks, reg.allocator)
	for i in 0..<n_blocks {
		envs[i].types = make(map[binder.Symbol_ID]Type_ID, 16, reg.allocator)
	}

	// Resolve function args for parameter type initialization
	scope := binder.result_get_scope(bind_result, cfg.scope_id)
	func_args: ^parser.Arguments = nil
	if scope != nil && (scope.kind == .Function || scope.kind == .Lambda) {
		if args, ok := func_args_map[cfg.scope_id]; ok {
			func_args = args
		}
	}

	// Determine enclosing class for super() support
	current_class := INVALID_TYPE
	if scope != nil && scope.kind == .Function {
		parent := binder.result_get_scope(bind_result, scope.parent_id)
		if parent != nil && parent.kind == .Class {
			for _, ct_id in reg.class_types {
				ct := get_type(reg, ct_id)
				#partial switch cls_info in ct.info {
				case Class_Type:
					if cls_info.scope_id == parent.id {
						current_class = ct_id
					}
				}
				if current_class != INVALID_TYPE { break }
			}
		}
	}

	// Collect return types for function return checking
	return_types := make([dynamic]Type_ID, 0, 8, reg.allocator)

	// Track declared annotation types across blocks (for reassignment checking)
	declared_types := make(map[binder.Symbol_ID]Type_ID, 16, reg.allocator)

	// Set global_types for non-module scopes (LEGB "G" fallback)
	global_types_ptr: ^map[binder.Symbol_ID]Type_ID = nil
	if scope != nil && scope.kind != .Module {
		global_types_ptr = &result.symbol_types
	}

	// Track diagnostic count before this scope (for dedup on constraint re-inference)
	diag_count_before_scope := len(result.diagnostics)

	// Match case pattern bindings (populated by check_match_stmt, consumed at BFS block entry)
	match_case_envs := make(map[flow.Block_ID]Match_Case_Env, 4, reg.allocator)

	// BFS walk from entry
	visited := make([]bool, n_blocks, reg.allocator)
	queue := make([dynamic]flow.Block_ID, 0, n_blocks, reg.allocator)
	append(&queue, cfg.entry)

	queue_head := 0
	for queue_head < len(queue) {
		block_id := queue[queue_head]
		queue_head += 1
		idx := int(block_id) - 1  // Block_IDs are 1-indexed

		if idx < 0 || idx >= n_blocks { continue }
		if visited[idx] { continue }
		visited[idx] = true

		block := flow.get_block(cfg, block_id)
		if block == nil || !block.is_reachable { continue }

		// Merge environments from predecessors
		env := merge_envs(block, envs[:], cfg, reg)

		// Seed import types into module-scope entry block
		if block_id == cfg.entry && import_types != nil {
			for sym_id, type_id in import_types {
				env.types[sym_id] = type_id
			}
		}

		// Initialize parameter types for the entry block (after merge to avoid overwrite)
		if block_id == cfg.entry && scope != nil && (scope.kind == .Function || scope.kind == .Lambda) {
			init_param_types(scope, bind_result, &env, reg, builtins, func_args, current_class)
		}

		// Apply narrowing guards
		apply_guards(&env, block_id, flow_result.guards[:], reg, bind_result, builtins)

		// Inject match case pattern bindings (populated by check_match_stmt)
		if mce, has_mce := match_case_envs[block_id]; has_mce {
			for sym_id, type_id in mce.bindings {
				env.types[sym_id] = type_id
			}
		}

		// Build inference context
		ctx := Infer_Context{
			env              = &env,
			reg              = reg,
			bind_result      = bind_result,
			builtins         = builtins,
			expr_types       = &result.expr_types,
			diagnostics      = &result.diagnostics,
			file_path        = file_path,
			declared_types   = &declared_types,
			current_class    = current_class,
			scope_id         = cfg.scope_id,
			global_types     = global_types_ptr,
			shape_reg        = shape_reg,
			const_map        = const_map,
			cfg              = cfg,
			current_block    = block_id,
			match_case_envs  = &match_case_envs,
		}

		// Process each statement in the block
		for stmt in block.stmts {
			check_stmt(stmt, &ctx, &return_types, declared_return)
		}

		// Store environment for successors
		envs[idx] = env

		// Enqueue successors
		for succ in block.succs {
			succ_idx := int(succ) - 1  // Block_IDs are 1-indexed
			if succ_idx >= 0 && succ_idx < n_blocks && !visited[succ_idx] {
				append(&queue, succ)
			}
		}
	}

	// Return type checking is done inline in check_stmt for Return_Stmt

	// --- Constraint-based backward inference ---
	// Find parameters that forward inference left as TYPE_UNKNOWN
	unknown_params := find_unknown_params(cfg, scope, envs[:], bind_result, reg)

	if len(unknown_params) > 0 {
		// Collect usage constraints from the function body
		cs := collect_scope_constraints(cfg, bind_result, reg, envs[:],
			&result.expr_types, &result.symbol_types, unknown_params[:], reg.allocator)

		// Resolve constraints → param types (method table passed from check())
		mt_local: Builtin_Method_Table
		mt_ptr := method_table
		if mt_ptr == nil {
			mt_local = init_method_table(reg)
			mt_ptr = &mt_local
		}
		resolved := resolve_constraints(&cs, mt_ptr, reg, reg.allocator)

		if len(resolved) > 0 {
			// Truncate diagnostics from the first pass — re-inference reproduces valid ones
			resize(&result.diagnostics, diag_count_before_scope)

			// Reset visited and envs for re-inference
			for i in 0..<n_blocks {
				visited[i] = false
				clear(&envs[i].types)
			}
			clear(&queue)
			append(&queue, cfg.entry)
			queue_head = 0
			clear(&return_types)

			for queue_head < len(queue) {
				block_id := queue[queue_head]
				queue_head += 1
				idx := int(block_id) - 1

				if idx < 0 || idx >= n_blocks { continue }
				if visited[idx] { continue }
				visited[idx] = true

				block := flow.get_block(cfg, block_id)
				if block == nil || !block.is_reachable { continue }

				env := merge_envs(block, envs[:], cfg, reg)

				if block_id == cfg.entry && import_types != nil {
					for sym_id, type_id in import_types {
						env.types[sym_id] = type_id
					}
				}

				if block_id == cfg.entry && scope != nil && (scope.kind == .Function || scope.kind == .Lambda) {
					init_param_types(scope, bind_result, &env, reg, builtins, func_args, current_class)
					// Inject constraint-resolved param types (override UNKNOWN)
					for sym_id, type_id in resolved {
						env.types[sym_id] = type_id
					}
				}

				apply_guards(&env, block_id, flow_result.guards[:], reg, bind_result, builtins)

				// Inject match case pattern bindings (re-inference pass)
				if mce, has_mce := match_case_envs[block_id]; has_mce {
					for sym_id, type_id in mce.bindings {
						env.types[sym_id] = type_id
					}
				}

				ctx := Infer_Context{
					env              = &env,
					reg              = reg,
					bind_result      = bind_result,
					builtins         = builtins,
					expr_types       = &result.expr_types,
					diagnostics      = &result.diagnostics,
					file_path        = file_path,
					declared_types   = &declared_types,
					current_class    = current_class,
					scope_id         = cfg.scope_id,
					global_types     = global_types_ptr,
					shape_reg        = shape_reg,
					const_map        = const_map,
					cfg              = cfg,
					current_block    = block_id,
					match_case_envs  = &match_case_envs,
				}

				for stmt in block.stmts {
					check_stmt(stmt, &ctx, &return_types, declared_return)
				}

				envs[idx] = env

				for succ in block.succs {
					succ_idx := int(succ) - 1
					if succ_idx >= 0 && succ_idx < n_blocks && !visited[succ_idx] {
						append(&queue, succ)
					}
				}
			}

			// Diagnostics truncated before re-inference (C01 fix) — no dedup needed
		}
	}

	// Store final symbol types — prefer exit block (has merged types from all paths)
	exit_idx := int(cfg.exit) - 1
	if exit_idx >= 0 && exit_idx < n_blocks && visited[exit_idx] {
		for sym_id, type_id in envs[exit_idx].types {
			result.symbol_types[sym_id] = type_id
		}
	} else {
		// Fallback: store from all visited blocks (exit block unreachable)
		for i in 0..<n_blocks {
			if visited[i] {
				for sym_id, type_id in envs[i].types {
					result.symbol_types[sym_id] = type_id
				}
			}
		}
	}

	// Infer function return type from body when no annotation present
	if declared_return == TYPE_UNKNOWN && scope != nil &&
	   (scope.kind == .Function || scope.kind == .Lambda) {
		inferred_ret := TYPE_NONE // default: implicit None return
		if len(return_types) == 1 {
			inferred_ret = return_types[0]
		} else if len(return_types) > 1 {
			inferred_ret = make_union_type(reg, return_types[:])
		}
		if inferred_ret != TYPE_UNKNOWN {
			result.inferred_returns[cfg.scope_id] = inferred_ret
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
		// Look up target's known type for contextual typing
		target_expected := TYPE_UNKNOWN
		if len(s.targets) == 1 {
			if name, ok := s.targets[0].(^parser.Name_Expr); ok {
				if sym_id, ref_ok := binder.get_ref(ctx.bind_result, rawptr(name)); ref_ok {
					if t, found := ctx.env.types[sym_id]; found {
						target_expected = t
					}
				}
			}
		}
		rhs_type := infer_expr(s.value, ctx, target_expected)
		// Check reassignment against declared annotation type
		if rhs_type != TYPE_UNKNOWN && rhs_type != TYPE_ANY {
			for target in s.targets {
				if name, ok := target.(^parser.Name_Expr); ok {
					if sym_id, ref_ok := binder.get_ref(ctx.bind_result, rawptr(name)); ref_ok {
						if declared, found := ctx.declared_types[sym_id]; found {
							if !is_assignable(ctx.reg, rhs_type, declared) {
								emit_diagnostic(ctx, s.loc, "T001", .Error,
									"Incompatible types in assignment",
									fmt_type_mismatch(rhs_type, declared, ctx.reg),
									"Change the value or the annotation")
							}
						}
					}
				}
			}
		}
		for target in s.targets {
			assign_target(target, rhs_type, ctx)
		}

	case ^parser.Ann_Assign:
		declared := resolve_annotation(s.annotation, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
		// Set the declared type on the symbol
		set_target_type(s.target, declared, ctx)

		// Record declared annotation type for reassignment checking
		if declared != TYPE_UNKNOWN && declared != TYPE_ANY {
			if name, ok := s.target.(^parser.Name_Expr); ok {
				if sym_id, ref_ok := binder.get_ref(ctx.bind_result, rawptr(name)); ref_ok {
					ctx.declared_types[sym_id] = declared
				}
			}
		}

		if s.value != nil {
			rhs_type := infer_expr(s.value, ctx, declared)
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
			ret_type := infer_expr(s.value, ctx, declared_return)
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
		// Record @overload signature if decorated (after set_name_type to ensure symbol is in env)
		if has_overload_decorator(s.decorator_list, ctx.bind_result) {
			for sym_id in ctx.env.types {
				sym := binder.result_get_symbol(ctx.bind_result, sym_id)
				if sym != nil && sym.name == s.name {
					if sym_id not_in ctx.reg.overload_sigs {
						ctx.reg.overload_sigs[sym_id] = make([dynamic]Type_ID, 0, 4, ctx.reg.allocator)
					}
					sigs := ctx.reg.overload_sigs[sym_id]
					append(&sigs, func_type)
					ctx.reg.overload_sigs[sym_id] = sigs
					break
				}
			}
		}

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
		// Type-check context manager expressions and bind optional_vars
		for item in s.items {
			cm_type := infer_expr(item.context_expr, ctx)
			if item.optional_vars != nil {
				// __enter__ return type approximated as the context manager type itself
				assign_target(item.optional_vars, cm_type, ctx)
			}
		}
	case ^parser.Async_With:
		for item in s.items {
			cm_type := infer_expr(item.context_expr, ctx)
			if item.optional_vars != nil {
				assign_target(item.optional_vars, cm_type, ctx)
			}
		}
	case ^parser.Async_For:
		iter_type := infer_expr(s.iter, ctx)
		elem_type := get_iterator_element_type(iter_type, ctx.reg)
		assign_target(s.target, elem_type, ctx)
	case ^parser.Try_Stmt:
	case ^parser.Try_Star:
	case ^parser.Match_Stmt:
		check_match_stmt(s, ctx)
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
		pred_idx := int(pred_id) - 1  // Block_IDs are 1-indexed
		if pred_idx < 0 || pred_idx >= len(envs) { continue }
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
	case .Is_Instance, .Is_Not_Instance, .Type_Is, .Type_Is_Not:
		// Narrow to the guard type. Inverted kinds (Is_Not_Instance) come from
		// unary `not` with block swap — double inversion cancels, same semantics.
		narrow_type := resolve_isinstance_type(guard.type_expr, reg, bind_result, builtins)
		if narrow_type != TYPE_UNKNOWN {
			env.types[guard.symbol_id] = narrow_type
		}
	case .Is_None, .Is_Not_None:
		env.types[guard.symbol_id] = TYPE_NONE
	case .Is_Truthy, .Is_Falsy:
		current, ok := env.types[guard.symbol_id]
		if ok {
			env.types[guard.symbol_id] = remove_none(reg, current)
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
	case .Is_Instance, .Is_Not_Instance, .Type_Is, .Type_Is_Not:
		// Subtract the guard type. Inverted kinds come from unary `not`
		// with block swap — double inversion cancels, same semantics.
		narrow_type := resolve_isinstance_type(guard.type_expr, reg, bind_result, builtins)
		current, ok := env.types[guard.symbol_id]
		if ok && narrow_type != TYPE_UNKNOWN {
			env.types[guard.symbol_id] = subtract_type(reg, current, narrow_type)
		}
	case .Is_None, .Is_Not_None:
		current, ok := env.types[guard.symbol_id]
		if ok {
			env.types[guard.symbol_id] = remove_none(reg, current)
		}
	case .Is_Truthy, .Is_Falsy:
		// In false branch of truthiness — could be None/False/0/empty
		// Conservative: don't narrow
		break
	}
}

// Resolve isinstance type arg — handles both single type and tuple (int, str) → union
resolve_isinstance_type :: proc(
	type_expr: parser.Expr,
	reg: ^Type_Registry,
	bind_result: ^binder.Bind_Result,
	builtins: ^Builtin_Names,
) -> Type_ID {
	// Check for tuple type arg: isinstance(x, (int, str))
	#partial switch te in type_expr {
	case ^parser.Tuple_Expr:
		if len(te.elts) > 0 {
			members := make([]Type_ID, len(te.elts), reg.allocator)
			for elt, i in te.elts {
				members[i] = resolve_annotation(elt, reg, bind_result, builtins)
			}
			return make_union_type(reg, members)
		}
	}
	return resolve_annotation(type_expr, reg, bind_result, builtins)
}

// ==================== Function/Class Type Building ====================

has_overload_decorator :: proc(decorators: []parser.Expr, bind_result: ^binder.Bind_Result) -> bool {
	for dec in decorators {
		#partial switch d in dec {
		case ^parser.Name_Expr:
			if orig, is_typing := bind_result.typing_names[d.id]; is_typing && orig == "overload" {
				return true
			}
		case ^parser.Attribute_Expr:
			if d.attr == "overload" { return true }
		}
	}
	return false
}

build_func_type :: proc(fd: ^parser.Func_Def, ctx: ^Infer_Context) -> Type_ID {
	params := resolve_params(&fd.args, ctx)

	// Detect @staticmethod/@classmethod decorators
	is_static := false
	is_classmethod := false
	for dec in fd.decorator_list {
		#partial switch d in dec {
		case ^parser.Name_Expr:
			if d.id == "staticmethod" { is_static = true }
			if d.id == "classmethod" { is_classmethod = true }
		case ^parser.Attribute_Expr:
			if d.attr == "staticmethod" { is_static = true }
			if d.attr == "classmethod" { is_classmethod = true }
		}
	}

	// Skip 'self'/'cls' parameter for methods (but not @staticmethod)
	actual_params := params
	if !is_static && len(params) > 0 && (params[0].name == "self" || params[0].name == "cls") {
		actual_params = params[1:]
	}

	ret_type := resolve_annotation(fd.returns, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
	return make_callable_type(ctx.reg, actual_params, ret_type)
}

build_async_func_type :: proc(fd: ^parser.Async_Func_Def, ctx: ^Infer_Context) -> Type_ID {
	params := resolve_params(&fd.args, ctx)

	// Check for @staticmethod / @classmethod
	is_static := false
	for dec in fd.decorator_list {
		#partial switch d in dec {
		case ^parser.Name_Expr:
			if d.id == "staticmethod" { is_static = true }
		case ^parser.Attribute_Expr:
			if d.attr == "staticmethod" { is_static = true }
		}
	}

	actual_params := params
	if !is_static && len(params) > 0 && (params[0].name == "self" || params[0].name == "cls") {
		actual_params = params[1:]
	}
	ret_type := resolve_annotation(fd.returns, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
	return make_callable_type(ctx.reg, actual_params, ret_type)
}

build_class_type :: proc(cd: ^parser.Class_Def, ctx: ^Infer_Context) -> Type_ID {
	// Find the scope for this class in binder
	scope_id := find_scope_for_def(cd.name, cd.loc, ctx.bind_result, .Class)

	// Check for special typing bases: TypedDict, Protocol
	is_typeddict := false
	is_protocol := false
	for base in cd.bases {
		base_name := ""
		#partial switch b in base {
		case ^parser.Name_Expr: base_name = b.id
		case ^parser.Subscript_Expr: base_name = get_annotation_name(b.value)
		}
		if orig, is_typing := ctx.bind_result.typing_names[base_name]; is_typing {
			if orig == "TypedDict" { is_typeddict = true }
			if orig == "Protocol" { is_protocol = true }
		}
	}

	// TypedDict class syntax
	if is_typeddict {
		return build_typeddict_class(cd, ctx, scope_id)
	}

	// Protocol class syntax
	if is_protocol {
		return build_protocol_class(cd, ctx, scope_id)
	}

	// Check for @dataclass decorator
	is_dataclass := false
	for dec in cd.decorator_list {
		#partial switch d in dec {
		case ^parser.Name_Expr:
			if d.id == "dataclass" { is_dataclass = true }
		case ^parser.Call_Expr:
			#partial switch f in d.func {
			case ^parser.Name_Expr:
				if f.id == "dataclass" { is_dataclass = true }
			case ^parser.Attribute_Expr:
				if f.attr == "dataclass" { is_dataclass = true }
			}
		case ^parser.Attribute_Expr:
			if d.attr == "dataclass" { is_dataclass = true }
		}
	}

	// Use pre-registered placeholder if exists, otherwise register new
	sym_id := find_symbol_for_name(cd.name, cd.loc, ctx.bind_result)
	class_type_id: Type_ID
	if sym_id != binder.INVALID_SYMBOL {
		if existing, found := ctx.reg.class_types[sym_id]; found {
			class_type_id = existing
		} else {
			class_type_id = register_type(ctx.reg, Class_Type{
				name      = cd.name,
				symbol_id = sym_id,
				scope_id  = scope_id,
			})
			ctx.reg.class_types[sym_id] = class_type_id
		}
	} else {
		class_type_id = register_type(ctx.reg, Class_Type{
			name      = cd.name,
			symbol_id = sym_id,
			scope_id  = scope_id,
		})
	}

	// Resolve base classes, detecting Generic[T] for type_params
	bases_dyn := make([dynamic]Type_ID, 0, len(cd.bases), ctx.reg.allocator)
	type_params_dyn := make([dynamic]Type_ID, 0, 4, ctx.reg.allocator)
	for base in cd.bases {
		// Check for Generic[T, U, ...] in bases
		if sub, ok := base.(^parser.Subscript_Expr); ok {
			base_name := get_annotation_name(sub.value)
			if orig, is_typing := ctx.bind_result.typing_names[base_name]; is_typing && orig == "Generic" {
				// Extract TypeVar IDs from subscript
				#partial switch _ in sub.slice {
				case ^parser.Tuple_Expr:
					tup := sub.slice.(^parser.Tuple_Expr)
					for elt in tup.elts {
						tv := resolve_annotation(elt, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
						if is_typevar(ctx.reg, tv) {
							append(&type_params_dyn, tv)
						}
					}
				case:
					tv := resolve_annotation(sub.slice, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
					if is_typevar(ctx.reg, tv) {
						append(&type_params_dyn, tv)
					}
				}
				continue // Don't add Generic to bases
			}
		}
		append(&bases_dyn, infer_expr(base, ctx))
	}
	bases := make([]Type_ID, len(bases_dyn), ctx.reg.allocator)
	copy(bases, bases_dyn[:])
	type_params: []Type_ID
	if len(type_params_dyn) > 0 {
		type_params = make([]Type_ID, len(type_params_dyn), ctx.reg.allocator)
		copy(type_params, type_params_dyn[:])
	}

	// Build attrs from class body
	attrs := make(map[string]Type_ID, 16, ctx.reg.allocator)

	// Scan class body for method and attribute definitions
	scan_class_body_attrs(cd.body, ctx, &attrs)

	// Inherit attributes from base classes (own attrs take precedence)
	for base_type_id in bases {
		base_t := get_type(ctx.reg, base_type_id)
		#partial switch base_cls in base_t.info {
		case Class_Type:
			for name, attr_type in base_cls.attrs {
				if name not_in attrs {
					attrs[name] = attr_type
				}
			}
		}
	}

	// @dataclass: auto-generate __init__, __repr__, __eq__
	if is_dataclass {
		init_params := make([dynamic]Param_Type, 0, 8, ctx.reg.allocator)

		// Collect parent dataclass fields first (MRO: parent fields before child)
		child_field_names := make(map[string]bool, 8, ctx.reg.allocator)
		for stmt in cd.body {
			#partial switch s in stmt {
			case ^parser.Ann_Assign:
				if name_expr, ok := s.target.(^parser.Name_Expr); ok {
					child_field_names[name_expr.id] = true
				}
			}
		}
		for base_type_id in bases {
			base_t := get_type(ctx.reg, base_type_id)
			#partial switch &base_cls in base_t.info {
			case Class_Type:
				if parent_init, ok := base_cls.attrs["__init__"]; ok {
					parent_init_t := get_type(ctx.reg, parent_init)
					#partial switch &parent_info in parent_init_t.info {
					case Callable_Type:
						for p in parent_info.params {
							// Skip fields overridden by child
							if !(p.name in child_field_names) {
								append(&init_params, p)
							}
						}
					}
				}
			}
		}

		// Then add child's own fields
		for stmt in cd.body {
			#partial switch s in stmt {
			case ^parser.Ann_Assign:
				if name_expr, ok := s.target.(^parser.Name_Expr); ok {
					field_type := resolve_annotation(s.annotation, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
					has_default := s.value != nil
					append(&init_params, Param_Type{name = name_expr.id, type_id = field_type, has_default = has_default})
				}
			}
		}
		attrs["__init__"] = make_callable_type(ctx.reg, init_params[:], TYPE_NONE)
		no_params := make([]Param_Type, 0, ctx.reg.allocator)
		attrs["__repr__"] = make_callable_type(ctx.reg, no_params, TYPE_STR)
		eq_params := make([]Param_Type, 1, ctx.reg.allocator)
		eq_params[0] = Param_Type{name = "other", type_id = TYPE_OBJECT}
		attrs["__eq__"] = make_callable_type(ctx.reg, eq_params, TYPE_BOOL)
	}

	// Update placeholder with actual class data
	ct := get_type(ctx.reg, class_type_id)
	#partial switch &info in ct.info {
	case Class_Type:
		info.bases = bases
		info.attrs = attrs
		info.type_params = type_params
	}

	return class_type_id
}

// TypedDict class syntax: class Movie(TypedDict): name: str; year: int
build_typeddict_class :: proc(cd: ^parser.Class_Def, ctx: ^Infer_Context, scope_id: binder.Scope_ID) -> Type_ID {
	fields := make(map[string]Type_ID, 16, ctx.reg.allocator)

	for stmt in cd.body {
		#partial switch s in stmt {
		case ^parser.Ann_Assign:
			if name_expr, ok := s.target.(^parser.Name_Expr); ok {
				field_type := resolve_annotation(s.annotation, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
				fields[name_expr.id] = field_type
			}
		}
	}

	sym_id := find_symbol_for_name(cd.name, cd.loc, ctx.bind_result)
	td_type_id := register_type(ctx.reg, TypedDict_Type{
		name   = cd.name,
		fields = fields,
		total  = true,
	})

	if sym_id != binder.INVALID_SYMBOL {
		ctx.reg.class_types[sym_id] = td_type_id
	}

	return td_type_id
}

// Protocol class syntax: class Drawable(Protocol): def draw(self) -> None: ...
build_protocol_class :: proc(cd: ^parser.Class_Def, ctx: ^Infer_Context, scope_id: binder.Scope_ID) -> Type_ID {
	methods := make(map[string]Type_ID, 8, ctx.reg.allocator)
	attrs := make(map[string]Type_ID, 8, ctx.reg.allocator)

	for stmt in cd.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			ft := build_func_type(s, ctx)
			methods[s.name] = ft
		case ^parser.Ann_Assign:
			if name_expr, ok := s.target.(^parser.Name_Expr); ok {
				field_type := resolve_annotation(s.annotation, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
				attrs[name_expr.id] = field_type
			}
		}
	}

	sym_id := find_symbol_for_name(cd.name, cd.loc, ctx.bind_result)
	proto_type_id := register_type(ctx.reg, Protocol_Type{
		name    = cd.name,
		methods = methods,
		attrs   = attrs,
	})

	if sym_id != binder.INVALID_SYMBOL {
		ctx.reg.class_types[sym_id] = proto_type_id
	}

	return proto_type_id
}

// Scan class body for method and attribute definitions, recursing into if/try/with blocks
scan_class_body_attrs :: proc(stmts: []parser.Stmt, ctx: ^Infer_Context, attrs: ^map[string]Type_ID) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			ft := build_func_type(s, ctx)
			attrs[s.name] = ft
			if s.name == "__init__" {
				scan_init_attrs(s, ctx, attrs)
			}
		case ^parser.Ann_Assign:
			declared := resolve_annotation(s.annotation, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
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
		case ^parser.If_Stmt:
			scan_class_body_attrs(s.body, ctx, attrs)
			scan_class_body_attrs(s.orelse, ctx, attrs)
		case ^parser.Try_Stmt:
			scan_class_body_attrs(s.body, ctx, attrs)
			for handler in s.handlers {
				scan_class_body_attrs(handler.body, ctx, attrs)
			}
			scan_class_body_attrs(s.orelse, ctx, attrs)
		case ^parser.With_Stmt:
			scan_class_body_attrs(s.body, ctx, attrs)
		}
	}
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
							// Infer attribute type from RHS
							val_type := TYPE_UNKNOWN
							if s.value != nil {
								// First try: self.x = x where x is a parameter
								if name, ok3 := s.value.(^parser.Name_Expr); ok3 {
									for arg in fd.args.args {
										if arg.arg == name.id {
											val_type = resolve_annotation(
												arg.annotation, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
											break
										}
									}
								}
								// Fallback: infer from RHS expression (handles literals, constructors, etc.)
								if val_type == TYPE_UNKNOWN {
									val_type = infer_expr(s.value, ctx)
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
						declared := resolve_annotation(s.annotation, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
						attrs[attr.attr] = declared
					}
				}
			}
		// Recurse into control flow blocks for conditional self.attr initialization
		case ^parser.If_Stmt:
			scan_init_attrs_stmts(fd, s.body, ctx, attrs)
			scan_init_attrs_stmts(fd, s.orelse, ctx, attrs)
		case ^parser.For_Stmt:
			scan_init_attrs_stmts(fd, s.body, ctx, attrs)
		case ^parser.While_Stmt:
			scan_init_attrs_stmts(fd, s.body, ctx, attrs)
		case ^parser.Try_Stmt:
			scan_init_attrs_stmts(fd, s.body, ctx, attrs)
			for handler in s.handlers {
				scan_init_attrs_stmts(fd, handler.body, ctx, attrs)
			}
		case ^parser.With_Stmt:
			scan_init_attrs_stmts(fd, s.body, ctx, attrs)
		}
	}
}

// Helper: recurse scan_init_attrs into nested statement blocks
scan_init_attrs_stmts :: proc(fd: ^parser.Func_Def, stmts: []parser.Stmt, ctx: ^Infer_Context, attrs: ^map[string]Type_ID) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Assign:
			for target in s.targets {
				if attr, ok := target.(^parser.Attribute_Expr); ok {
					if self_name, ok2 := attr.value.(^parser.Name_Expr); ok2 {
						if self_name.id == "self" && s.value != nil {
							val_type := infer_expr(s.value, ctx)
							attrs[attr.attr] = val_type
						}
					}
				}
			}
		case ^parser.Ann_Assign:
			if attr, ok := s.target.(^parser.Attribute_Expr); ok {
				if self_name, ok2 := attr.value.(^parser.Name_Expr); ok2 {
					if self_name.id == "self" {
						declared := resolve_annotation(s.annotation, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
						attrs[attr.attr] = declared
					}
				}
			}
		case ^parser.If_Stmt:
			scan_init_attrs_stmts(fd, s.body, ctx, attrs)
			scan_init_attrs_stmts(fd, s.orelse, ctx, attrs)
		case ^parser.Try_Stmt:
			scan_init_attrs_stmts(fd, s.body, ctx, attrs)
			for handler in s.handlers {
				scan_init_attrs_stmts(fd, handler.body, ctx, attrs)
			}
		case ^parser.For_Stmt:
			scan_init_attrs_stmts(fd, s.body, ctx, attrs)
		case ^parser.While_Stmt:
			scan_init_attrs_stmts(fd, s.body, ctx, attrs)
		case ^parser.With_Stmt:
			scan_init_attrs_stmts(fd, s.body, ctx, attrs)
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
	// Find symbol for this name in current env (already scoped)
	for sym_id, sym_type in ctx.env.types {
		sym := binder.result_get_symbol(ctx.bind_result, sym_id)
		if sym != nil && sym.name == name {
			ctx.env.types[sym_id] = type_id
			return
		}
	}
	// If not in env yet, search in bind_result — prefer current scope
	scope := binder.result_get_scope(ctx.bind_result, ctx.scope_id)
	if scope != nil {
		for _, sym_id in scope.symbols {
			sym := binder.result_get_symbol(ctx.bind_result, sym_id)
			if sym != nil && sym.name == name {
				ctx.env.types[sym_id] = type_id
				return
			}
		}
	}
	// Last resort: any symbol with this name
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

// ==================== Pre-registration ====================

// Pre-register all class names so that return type annotations (-> MyClass) can resolve them.
// Only registers placeholder Class_Types — full class body processing happens later in check_scope.
pre_register_classes :: proc(stmts: []parser.Stmt, bind_result: ^binder.Bind_Result, reg: ^Type_Registry) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Class_Def:
			sym_id := find_symbol_for_name(s.name, s.loc, bind_result)
			// Skip if already registered (e.g., from imports)
			if sym_id != binder.INVALID_SYMBOL {
				if _, already := reg.class_types[sym_id]; already { continue }
			}
			scope_id := find_scope_for_def(s.name, s.loc, bind_result, .Class)
			class_type_id := register_type(reg, Class_Type{
				name      = s.name,
				symbol_id = sym_id,
				scope_id  = scope_id,
			})
			if sym_id != binder.INVALID_SYMBOL {
				reg.class_types[sym_id] = class_type_id
			}
			// Recurse for nested classes
			pre_register_classes(s.body, bind_result, reg)

		case ^parser.If_Stmt:
			pre_register_classes(s.body, bind_result, reg)
			pre_register_classes(s.orelse, bind_result, reg)
		case ^parser.For_Stmt:
			pre_register_classes(s.body, bind_result, reg)
		case ^parser.While_Stmt:
			pre_register_classes(s.body, bind_result, reg)
		case ^parser.Try_Stmt:
			pre_register_classes(s.body, bind_result, reg)
			for handler in s.handlers {
				pre_register_classes(handler.body, bind_result, reg)
			}
			pre_register_classes(s.orelse, bind_result, reg)
		case ^parser.With_Stmt:
			pre_register_classes(s.body, bind_result, reg)
		case ^parser.Func_Def:
			pre_register_classes(s.body, bind_result, reg)
		}
	}
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
			for handler in s.handlers {
				collect_func_return_types(handler.body, bind_result, reg, builtins, out)
			}
			collect_func_return_types(s.finalbody, bind_result, reg, builtins, out)
			collect_func_return_types(s.orelse, bind_result, reg, builtins, out)
		}
	}
}

collect_func_args :: proc(
	stmts: []parser.Stmt,
	bind_result: ^binder.Bind_Result,
	out: ^map[binder.Scope_ID]^parser.Arguments,
) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			scope_id := find_scope_for_def(s.name, s.loc, bind_result, .Function)
			if scope_id != binder.INVALID_SCOPE {
				out[scope_id] = &s.args
			}
			collect_func_args(s.body, bind_result, out)
		case ^parser.Async_Func_Def:
			scope_id := find_scope_for_def(s.name, s.loc, bind_result, .Function)
			if scope_id != binder.INVALID_SCOPE {
				out[scope_id] = &s.args
			}
			collect_func_args(s.body, bind_result, out)
		case ^parser.Class_Def:
			collect_func_args(s.body, bind_result, out)
		case ^parser.If_Stmt:
			collect_func_args(s.body, bind_result, out)
			collect_func_args(s.orelse, bind_result, out)
		case ^parser.For_Stmt:
			collect_func_args(s.body, bind_result, out)
		case ^parser.While_Stmt:
			collect_func_args(s.body, bind_result, out)
		case ^parser.Try_Stmt:
			collect_func_args(s.body, bind_result, out)
			for handler in s.handlers {
				collect_func_args(handler.body, bind_result, out)
			}
			collect_func_args(s.orelse, bind_result, out)
			collect_func_args(s.finalbody, bind_result, out)
		case ^parser.With_Stmt:
			collect_func_args(s.body, bind_result, out)
		}
	}
}

// ==================== Post-Backfill Revalidation ====================

// After inferred return types are backfilled into Callable_Types, re-check module-level
// assignments that reference those functions. Without this, `x: int = f()` passes during
// initial check (f returns TYPE_UNKNOWN), but should fail after backfill reveals f returns str.
revalidate_module_calls :: proc(
	stmts: []parser.Stmt,
	result: ^Check_Result,
	bind_result: ^binder.Bind_Result,
	builtins: ^Builtin_Names,
	file_path: string,
	reg_override: ^Type_Registry = nil,
) {
	reg := reg_override if reg_override != nil else &result.registry

	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Ann_Assign:
			if s.value == nil { continue }
			declared := resolve_annotation(s.annotation, reg, bind_result, builtins)
			if declared == TYPE_UNKNOWN || declared == TYPE_ANY { continue }

			call_type := reinfer_call_return(s.value, result, bind_result, reg, builtins)
			if call_type == TYPE_UNKNOWN || call_type == TYPE_ANY { continue }

			if !is_assignable(reg, call_type, declared) {
				emit_diagnostic_raw(&result.diagnostics, file_path, s.loc, "T001", .Error,
					"Incompatible types in assignment",
					fmt_type_mismatch(call_type, declared, reg),
					"Change the value or the annotation")
			}

		case ^parser.Assign:
			if s.value == nil { continue }
			if len(s.targets) != 1 { continue }

			// Check if target has a declared type
			if name, ok := s.targets[0].(^parser.Name_Expr); ok {
				sym_id, ref_ok := binder.get_ref(bind_result, rawptr(name))
				if !ref_ok { continue }

				// Check declared annotation types from symbol_types
				declared, has_declared := result.symbol_types[sym_id]
				if !has_declared || declared == TYPE_UNKNOWN || declared == TYPE_ANY { continue }

				call_type := reinfer_call_return(s.value, result, bind_result, reg, builtins)
				if call_type == TYPE_UNKNOWN || call_type == TYPE_ANY { continue }

				if !is_assignable(reg, call_type, declared) {
					emit_diagnostic_raw(&result.diagnostics, file_path, s.loc, "T001", .Error,
						"Incompatible types in assignment",
						fmt_type_mismatch(call_type, declared, reg),
						"Change the value or the annotation")
				}
			}
		}
	}
}

// Re-infer the return type of a call expression using updated callable types
reinfer_call_return :: proc(
	expr: parser.Expr,
	result: ^Check_Result,
	bind_result: ^binder.Bind_Result,
	reg: ^Type_Registry,
	builtins: ^Builtin_Names,
) -> Type_ID {
	if expr == nil { return TYPE_UNKNOWN }

	call, ok := expr.(^parser.Call_Expr)
	if !ok { return TYPE_UNKNOWN }

	// Get the function being called
	if name, name_ok := call.func.(^parser.Name_Expr); name_ok {
		sym_id, ref_ok := binder.get_ref(bind_result, rawptr(name))
		if !ref_ok { return TYPE_UNKNOWN }

		func_type_id, has_type := result.symbol_types[sym_id]
		if !has_type { return TYPE_UNKNOWN }

		t := get_type(reg, func_type_id)
		#partial switch info in t.info {
		case Callable_Type:
			return info.return_type
		}
	}

	return TYPE_UNKNOWN
}

// Emit a diagnostic without requiring an Infer_Context
emit_diagnostic_raw :: proc(
	diagnostics: ^[dynamic]core.Diagnostic,
	file_path: string,
	loc: parser.Src_Loc,
	code: string,
	severity: core.Severity,
	what: string,
	why: string,
	fix: string,
) {
	append(diagnostics, core.Diagnostic{
		severity = severity,
		location = core.Location{
			file   = file_path,
			line   = int(loc.line),
			column = int(loc.col),
		},
		code = code,
		what = what,
		why  = why,
		fix  = fix,
	})
}

// ==================== Return Type Backfill ====================

// After all scopes are checked, update Callable_Types with body-inferred return types.
// This makes return types visible to symbol_types queries, LSP hover, and cross-module callers.
// Within-module callers in the same check pass won't see the update (Phase II: iterative fixpoint).
backfill_inferred_returns :: proc(result: ^Check_Result, bind_result: ^binder.Bind_Result, reg_override: ^Type_Registry = nil) {
	reg := reg_override if reg_override != nil else &result.registry

	for scope_id, inferred_ret in result.inferred_returns {
		// Find the function's symbol via scope
		scope := binder.result_get_scope(bind_result, scope_id)
		if scope == nil { continue }

		// Look up the parent scope to find the function symbol
		parent := binder.result_get_scope(bind_result, scope.parent_id)
		if parent == nil { continue }

		// Find function symbol by name in parent scope
		func_sym_id, found := parent.symbols[scope.name]
		if !found { continue }

		// Skip overloaded functions — callers use overload resolution, not body inference
		if func_sym_id in reg.overload_sigs { continue }

		// Get the function's type from symbol_types
		func_type_id, has_type := result.symbol_types[func_sym_id]
		if !has_type { continue }

		// Update the Callable_Type's return_type in-place
		t := get_type(reg, func_type_id)
		#partial switch &info in t.info {
		case Callable_Type:
			if info.return_type == TYPE_UNKNOWN {
				info.return_type = inferred_ret
			}
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
	func_args: ^parser.Arguments = nil,
	current_class: Type_ID = INVALID_TYPE,
) {
	// Build param name → annotation map from function args
	param_annotations: map[string]parser.Expr
	if func_args != nil {
		param_annotations.allocator = reg.allocator
		for a in func_args.posonlyargs {
			if a.annotation != nil { param_annotations[a.arg] = a.annotation }
		}
		for a in func_args.args {
			if a.annotation != nil { param_annotations[a.arg] = a.annotation }
		}
		for a in func_args.kwonlyargs {
			if a.annotation != nil { param_annotations[a.arg] = a.annotation }
		}
	}

	// Set parameter symbols to their annotated types or UNKNOWN
	for _, sym_id in scope.symbols {
		sym := binder.result_get_symbol(bind_result, sym_id)
		if sym == nil { continue }
		if .Is_Param in sym.flags {
			// self parameter → Instance_Type of enclosing class
			if sym.name == "self" && current_class != INVALID_TYPE {
				env.types[sym_id] = make_instance_type(reg, current_class)
				continue
			}
			if ann, ok := param_annotations[sym.name]; ok {
				resolved := resolve_annotation(ann, reg, bind_result, builtins)
				env.types[sym_id] = resolved != TYPE_UNKNOWN ? resolved : TYPE_UNKNOWN
			} else {
				env.types[sym_id] = TYPE_UNKNOWN
			}
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
