package checker

import "core:fmt"
import "core:mem"
import "core:strings"

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

	// Assign file_id for single-file mode
	result.registry.next_file_id += 1
	result.registry.current_file_id = result.registry.next_file_id

	// Pre-register all classes so return type annotations can reference them
	pre_register_classes(module.body, bind_result, &result.registry)

	// Build scope→return type map and scope→args map by scanning AST
	return_type_map := make(map[binder.Scope_ID]Type_ID, 16, allocator)
	func_args_map := make(map[binder.Scope_ID]^parser.Arguments, 16, allocator)
	collect_func_return_types(module.body, bind_result, &result.registry, &builtins, &return_type_map)
	collect_func_args(module.body, bind_result, &func_args_map)

	// Collect Generator[Y, S, R] send types for yield expression typing
	generator_send_types := make(map[binder.Scope_ID]Type_ID, 4, allocator)
	collect_generator_send_types(module.body, bind_result, &result.registry, &builtins, &generator_send_types)

	// §31.2: Collect pytest fixture return types for injection into test params
	fixture_types := collect_fixture_types(module.body, bind_result, &return_type_map)

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
		fixture_ptr: ^map[string]Type_ID = nil
		if len(fixture_types) > 0 { fixture_ptr = &fixture_types }
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
			fixture_types = fixture_ptr,
			generator_send_types = &generator_send_types if len(generator_send_types) > 0 else nil,
		)
	}

	// ==================== Fixed-Point Convergence Loop (§3.2) ====================
	// Iterate: backfill returns → collect caller→param types → re-check → repeat
	// Converges when no new return types or param types are discovered.
	MAX_FIXPOINT_ROUNDS :: 5

	backfill_inferred_returns(&result, bind_result)

	prev_return_count := len(result.inferred_returns)
	prev_caller_count := 0
	prev_caller_hash : u64 = 0
	caller_param_types: Caller_Param_Types
	sym_to_scope := build_sym_to_scope(bind_result, allocator)

	for round in 0..<MAX_FIXPOINT_ROUNDS {

		// Collect caller→param types from call sites
		caller_param_types = collect_caller_param_types(
			&result, bind_result, flow_result, &func_args_map, &sym_to_scope, &result.registry, allocator)

		// Count total caller param evidence + type hash for change detection
		new_caller_count := 0
		new_caller_hash : u64 = 0
		for scope_id, params in caller_param_types {
			new_caller_count += len(params)
			for idx, type_id in params {
				new_caller_hash ~= u64(type_id) * (u64(scope_id) + u64(idx) * 31 + 1)
			}
		}

		// On first round, skip if no evidence at all
		if round == 0 && len(result.inferred_returns) == 0 && new_caller_count == 0 { break }

		// Re-check unannotated function/lambda scopes with new evidence
		for &cfg in flow_result.cfgs {
			scope := binder.result_get_scope(bind_result, cfg.scope_id)
			if scope == nil { continue }
			if scope.kind != .Function && scope.kind != .Lambda { continue }

			declared_return := TYPE_UNKNOWN
			if ret, ok := return_type_map[cfg.scope_id]; ok {
				declared_return = ret
			}
			if declared_return != TYPE_UNKNOWN { continue }

			fixpoint_cm: ^flow.Const_Map = nil
			if scope_cm, ok := &flow_result.const_maps[cfg.scope_id]; ok {
				fixpoint_cm = scope_cm
			}

			// Get caller evidence for this scope (if any)
			scope_caller_types: map[int]Type_ID
			if cfg.scope_id in caller_param_types {
				scope_caller_types = caller_param_types[cfg.scope_id]
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
				caller_param_types = scope_caller_types,
				generator_send_types = &generator_send_types if len(generator_send_types) > 0 else nil,
			)
		}

		// Backfill newly inferred returns
		backfill_inferred_returns(&result, bind_result)

		// Check convergence: did we discover new return types or caller params?
		new_return_count := len(result.inferred_returns)
		if new_return_count == prev_return_count && new_caller_count == prev_caller_count && new_caller_hash == prev_caller_hash { break }
		prev_return_count = new_return_count
		prev_caller_count = new_caller_count
		prev_caller_hash = new_caller_hash
	}

	// §3.4: Per-call-site specialization for unannotated generic functions
	{
		call_sites := collect_call_sites(
			&result, bind_result, flow_result, &sym_to_scope, &func_args_map, &result.registry, allocator)
		if len(call_sites) > 0 {
			specialize_call_sites(
				&result, bind_result, flow_result, call_sites[:], &func_args_map,
				&builtins, &mt, file_path, shape_reg_ptr, allocator)
			// Backfill widened return types into Callable_Types
			backfill_inferred_returns(&result, bind_result)
		}
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
	discovered_routes: []Route_Info
	if len(virtual_imports) > 0 {
		discovered_routes = analyze_routes(module, bind_result, &result.registry, &virtual_imports, file_path, &result.diagnostics, allocator)
	}

	// API contract pass — validate routes against openapi.json
	if len(discovered_routes) > 0 {
		analyze_api_contracts(module, discovered_routes, file_path, &result.diagnostics, allocator)
	}

	// ==================== Shared Analysis Context ====================
	// Built once, shared across all post-inference passes.
	// Eliminates 15+ duplicate import detection loops.
	actx := build_analysis_pass_context(
		module, bind_result, file_path, allocator,
		&result.expr_types, &result.registry,
	)

	// All passes below use shared actx for import detection

	// Batched AST walk: json + db + crypt in one traversal
	{
		batch_visitors := make([dynamic]core.AST_Visitor, 0, 3, allocator)
		json_ctx: JSON_Check_Context
		db_ctx: DB_Check_Context
		crypt_ctx: Crypt_Check_Context

		if v, ok := make_json_visitor(&actx, &result.diagnostics, &json_ctx); ok {
			append(&batch_visitors, v)
		}
		if v, ok := make_db_visitor(&actx, &virtual_imports, &result.diagnostics, &db_ctx); ok {
			append(&batch_visitors, v)
		}
		if v, ok := make_crypt_visitor(&actx, &result.diagnostics, &crypt_ctx); ok {
			append(&batch_visitors, v)
		}
		if len(batch_visitors) > 0 {
			core.walk_all_stmts_multi(batch_visitors[:], module.body)
		}
	}

	analyze_regex(&actx, &result.diagnostics)
	analyze_time_encoding(&actx, &result.diagnostics)
	analyze_compat(&actx, &result.diagnostics)
	analyze_serialization(&actx, &result.diagnostics)
	analyze_ml(&actx, &result.diagnostics)
	analyze_typestate(module, bind_result, file_path, &result.diagnostics, allocator) // not yet migrated
	analyze_crossproc(&actx, &result.diagnostics)
	analyze_runtime_model(&actx, &result.diagnostics)

	// §12: DataFrame unnecessary copy detection
	check_unnecessary_copy(module.body, file_path, &result.diagnostics)

	// D001: unused variable detection (DFG-backed)
	detect_unused_variables(flow_result, bind_result, file_path, &result.diagnostics, allocator)

	// §31.2: Mock spec + fixture type checking
	analyze_test_patterns(module, bind_result, &result.registry, &result.expr_types, file_path, &result.diagnostics, allocator)

	// Suppress F002 for functions that contain Never-returning calls
	suppress_f002_for_never(flow_result, &result, bind_result)

	return result
}

// F002 suppression: if a function body contains a call to a Never-returning function,
// the function is guaranteed to terminate on that path. Remove the F002 diagnostic.
suppress_f002_for_never :: proc(flow_result: ^flow.Flow_Result, result: ^Check_Result, bind_result: ^binder.Bind_Result) {
	// Collect scope_ids that have Never-returning calls in their bodies
	never_scopes := make(map[binder.Scope_ID]bool, 4, result.registry.allocator)
	for &cfg in flow_result.cfgs {
		scope := binder.result_get_scope(bind_result, cfg.scope_id)
		if scope == nil || scope.kind != .Function { continue }
		for &block in cfg.blocks {
			if !block.is_reachable { continue }
			for stmt in block.stmts {
				if es, ok := stmt.(^parser.Expr_Stmt); ok {
					if call, c_ok := es.value.(^parser.Call_Expr); c_ok {
						call_type := TYPE_UNKNOWN
						if t, found := result.expr_types[rawptr(call)]; found {
							call_type = t
						}
						if call_type == TYPE_NEVER {
							never_scopes[cfg.scope_id] = true
						}
					}
				}
			}
		}
	}
	if len(never_scopes) == 0 { return }

	// Remove F002 diagnostics for functions with Never-returning calls
	i := 0
	for i < len(flow_result.diagnostics) {
		d := flow_result.diagnostics[i]
		if d.code == "F002" {
			// Match by location — find the scope at this line
			suppressed := false
			for &cfg in flow_result.cfgs {
				if cfg.scope_id in never_scopes {
					scope := binder.result_get_scope(bind_result, cfg.scope_id)
					if scope != nil && int(scope.loc.line) == d.location.line {
						suppressed = true
						break
					}
				}
			}
			if suppressed {
				ordered_remove(&flow_result.diagnostics, i)
				continue
			}
		}
		i += 1
	}
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

	// Assign file_id for this file — makes class_types keys globally unique
	registry.next_file_id += 1
	registry.current_file_id = registry.next_file_id

	// Register imported class types under this file's qualified key
	for sym_id, type_id in import_types {
		t := get_type(registry, type_id)
		#partial switch _ in t.info {
		case Class_Type:
			registry.class_types[qualify(registry, sym_id)] = type_id
		}
	}

	// Pre-register all classes
	pre_register_classes(module.body, bind_result, registry)

	return_type_map := make(map[binder.Scope_ID]Type_ID, 16, allocator)
	func_args_map := make(map[binder.Scope_ID]^parser.Arguments, 16, allocator)
	collect_func_return_types(module.body, bind_result, registry, builtins, &return_type_map)
	collect_func_args(module.body, bind_result, &func_args_map)

	// Collect Generator[Y, S, R] send types
	generator_send_types := make(map[binder.Scope_ID]Type_ID, 4, allocator)
	collect_generator_send_types(module.body, bind_result, registry, builtins, &generator_send_types)
	gen_send_ptr: ^map[binder.Scope_ID]Type_ID = nil
	if len(generator_send_types) > 0 { gen_send_ptr = &generator_send_types }

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
			generator_send_types = gen_send_ptr,
		)
	}

	// ==================== Fixed-Point Convergence Loop (§3.2) ====================
	MAX_FIXPOINT_ROUNDS_MULTI :: 5
	backfill_inferred_returns(&result, bind_result, registry)

	prev_ret_count := len(result.inferred_returns)
	prev_caller_count_multi := 0
	prev_caller_hash_multi : u64 = 0
	caller_param_types_multi: Caller_Param_Types
	sym_to_scope_multi := build_sym_to_scope(bind_result, allocator)

	for round in 0..<MAX_FIXPOINT_ROUNDS_MULTI {

		caller_param_types_multi = collect_caller_param_types(
			&result, bind_result, flow_result, &func_args_map, &sym_to_scope_multi, registry, allocator)

		new_caller_count_multi := 0
		new_caller_hash_multi : u64 = 0
		for scope_id, params in caller_param_types_multi {
			new_caller_count_multi += len(params)
			for idx, type_id in params {
				new_caller_hash_multi ~= u64(type_id) * (u64(scope_id) + u64(idx) * 31 + 1)
			}
		}
		if round == 0 && len(result.inferred_returns) == 0 && new_caller_count_multi == 0 { break }

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
			scope_caller_types_multi: map[int]Type_ID
			if cfg.scope_id in caller_param_types_multi {
				scope_caller_types_multi = caller_param_types_multi[cfg.scope_id]
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
				caller_param_types = scope_caller_types_multi,
				generator_send_types = gen_send_ptr,
			)
		}

		backfill_inferred_returns(&result, bind_result, registry)

		new_ret_count := len(result.inferred_returns)
		if new_ret_count == prev_ret_count && new_caller_count_multi == prev_caller_count_multi && new_caller_hash_multi == prev_caller_hash_multi { break }
		prev_ret_count = new_ret_count
		prev_caller_count_multi = new_caller_count_multi
		prev_caller_hash_multi = new_caller_hash_multi
	}

	// §3.4: Per-call-site specialization (multi-module)
	{
		call_sites_multi := collect_call_sites(
			&result, bind_result, flow_result, &sym_to_scope_multi, &func_args_map, registry, allocator)
		if len(call_sites_multi) > 0 {
			specialize_call_sites(
				&result, bind_result, flow_result, call_sites_multi[:], &func_args_map,
				builtins, &mt, file_path, shape_reg_ptr, allocator, registry)
			backfill_inferred_returns(&result, bind_result, registry)
		}
	}

	if len(result.inferred_returns) > 0 {
		revalidate_module_calls(module.body, &result, bind_result, builtins, file_path, registry)
	}

	// Shape analysis pass
	if len(shape_reg.semantics) > 0 {
		analyze_shapes(flow_result, &result, bind_result, &shape_reg, file_path, allocator)
	}

	// Route analysis pass — validate mimir.http route decorators
	discovered_routes: []Route_Info
	if len(virtual_imports) > 0 {
		discovered_routes = analyze_routes(module, bind_result, registry, &virtual_imports, file_path, &result.diagnostics, allocator)
	}

	// API contract pass — validate routes against openapi.json
	if len(discovered_routes) > 0 {
		analyze_api_contracts(module, discovered_routes, file_path, &result.diagnostics, allocator)
	}

	// ==================== Shared Analysis Context (multi-module) ====================
	actx_multi := build_analysis_pass_context(
		module, bind_result, file_path, allocator,
		&result.expr_types, registry,
	)

	// All passes below use shared actx_multi for import detection

	// Batched AST walk: json + db + crypt in one traversal
	{
		batch_visitors_m := make([dynamic]core.AST_Visitor, 0, 3, allocator)
		json_ctx_m: JSON_Check_Context
		db_ctx_m: DB_Check_Context
		crypt_ctx_m: Crypt_Check_Context

		if v, ok := make_json_visitor(&actx_multi, &result.diagnostics, &json_ctx_m); ok {
			append(&batch_visitors_m, v)
		}
		if v, ok := make_db_visitor(&actx_multi, &virtual_imports, &result.diagnostics, &db_ctx_m); ok {
			append(&batch_visitors_m, v)
		}
		if v, ok := make_crypt_visitor(&actx_multi, &result.diagnostics, &crypt_ctx_m); ok {
			append(&batch_visitors_m, v)
		}
		if len(batch_visitors_m) > 0 {
			core.walk_all_stmts_multi(batch_visitors_m[:], module.body)
		}
	}

	analyze_regex(&actx_multi, &result.diagnostics)
	analyze_time_encoding(&actx_multi, &result.diagnostics)
	analyze_compat(&actx_multi, &result.diagnostics)
	analyze_serialization(&actx_multi, &result.diagnostics)
	analyze_ml(&actx_multi, &result.diagnostics)
	analyze_typestate(module, bind_result, file_path, &result.diagnostics, allocator) // not yet migrated
	analyze_crossproc(&actx_multi, &result.diagnostics)
	analyze_runtime_model(&actx_multi, &result.diagnostics)

	// §12: DataFrame unnecessary copy detection
	check_unnecessary_copy(module.body, file_path, &result.diagnostics)

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
	caller_param_types: map[int]Type_ID = nil,
	fixture_types: ^map[string]Type_ID = nil,
	generator_send_types: ^map[binder.Scope_ID]Type_ID = nil,
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

	// Determine enclosing class for super() support and self type resolution
	current_class := INVALID_TYPE
	if scope != nil && scope.kind == .Function {
		parent := binder.result_get_scope(bind_result, scope.parent_id)
		if parent != nil && parent.kind == .Class {
			// Primary: look up the class symbol by name in the module scope,
			// then use class_types[sym_id] for reliable resolution.
			// (scope_id matching is unreliable when stubs are loaded — scope_ids
			// from typeshed and user code can collide)
			class_sym := find_symbol_for_name(parent.name, parent.loc, bind_result)
			if class_sym != binder.INVALID_SYMBOL {
				if ct_id, found := reg.class_types[qualify(reg, class_sym)]; found {
					current_class = ct_id
				}
			}
			// Fallback: match by scope_id (pre-stub behavior)
			if current_class == INVALID_TYPE {
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
	}

	// Collect return types for function return checking
	return_types := make([dynamic]Type_ID, 0, 8, reg.allocator)

	// Track declared annotation types across blocks (for reassignment checking)
	declared_types := make(map[binder.Symbol_ID]Type_ID, 16, reg.allocator)

	// Track Final[T] variables (cannot be reassigned)
	final_vars := make(map[binder.Symbol_ID]bool, 4, reg.allocator)

	// Track groupby source DataFrames for column-aware aggregation
	groupby_sources := make(map[binder.Symbol_ID]GroupBy_Info, 4, reg.allocator)

	// §4.2: Track variables closed after with-block exit
	closed_vars := make(map[binder.Symbol_ID]parser.Src_Loc, 4, reg.allocator)

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
			// §31.2: Inject fixture types for test function params
			if fixture_types != nil && strings.has_prefix(scope.name, "test_") {
				inject_fixture_types(scope, bind_result, &env, fixture_types)
			}
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
			groupby_sources  = &groupby_sources,
			closed_vars      = &closed_vars,
			final_vars       = &final_vars,
				generator_send_types = generator_send_types,
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
	// Find symbols that forward inference left as TYPE_UNKNOWN (params + locals)
	unknown_syms_list := find_unknown_symbols(cfg, scope, envs[:], bind_result, reg, visited[:])

	if len(unknown_syms_list) > 0 || len(caller_param_types) > 0 {
		// Collect usage constraints from the function body
		cs := collect_scope_constraints(cfg, bind_result, reg, envs[:],
			&result.expr_types, &result.symbol_types, unknown_syms_list[:], reg.allocator)

		// Resolve constraints → param types (method table passed from check())
		mt_local: Builtin_Method_Table
		mt_ptr := method_table
		if mt_ptr == nil {
			mt_local = init_method_table(reg)
			mt_ptr = &mt_local
		}

		// Use caller-aware resolution when caller evidence is available
		resolved: map[binder.Symbol_ID]Type_ID
		constraint_conflicts := make([dynamic]Constraint_Conflict, 0, 4, reg.allocator)
		if len(caller_param_types) > 0 {
			resolved = resolve_constraints_with_callers(
				&cs, mt_ptr, reg, scope, bind_result, caller_param_types, func_args, reg.allocator, &constraint_conflicts)
		} else {
			resolved = resolve_constraints(&cs, mt_ptr, reg, reg.allocator)
		}

		// Emit T010 for any body/caller conflicts (from constraint resolution)
		for &conflict in constraint_conflicts {
			caller_str := type_to_string(reg, conflict.caller_type)
			emit_diagnostic_raw(&result.diagnostics, file_path, conflict.loc, "T010", .Warning,
				"Conflicting type constraints",
				fmt.tprintf("Parameter '%s' called with '%s' but body usage requires a different type",
					conflict.param_name, caller_str),
				"Check call sites or add type annotation to resolve ambiguity")
		}

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
					groupby_sources  = &groupby_sources,
					final_vars       = &final_vars,
					resolved_types   = &resolved,
					generator_send_types = generator_send_types,
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

	// T010: Check caller→param type conflicts against final inferred param types
	if scope != nil && func_args != nil && len(caller_param_types) > 0 {
		entry_idx := int(cfg.entry) - 1
		if entry_idx >= 0 && entry_idx < n_blocks {
			idx := 0
			for &arg in func_args.posonlyargs {
				check_caller_conflict(&arg, idx, scope, &envs[entry_idx], caller_param_types, reg, &result.diagnostics, file_path)
				idx += 1
			}
			for &arg in func_args.args {
				check_caller_conflict(&arg, idx, scope, &envs[entry_idx], caller_param_types, reg, &result.diagnostics, file_path)
				idx += 1
			}
		}
	}

	// Infer function return type from body when no annotation present
	if declared_return == TYPE_UNKNOWN && scope != nil &&
	   (scope.kind == .Function || scope.kind == .Lambda) {
		// Filter out TYPE_UNKNOWN from return_types — recursive calls produce
		// Unknown returns (the function's own return type isn't inferred yet).
		// If concrete types exist alongside Unknown, use only the concrete ones.
		concrete_returns := make([dynamic]Type_ID, 0, len(return_types), reg.allocator)
		for rt in return_types {
			if rt != TYPE_UNKNOWN {
				append(&concrete_returns, rt)
			}
		}

		inferred_ret := TYPE_NONE // default: implicit None return
		if len(concrete_returns) == 1 {
			inferred_ret = concrete_returns[0]
		} else if len(concrete_returns) > 1 {
			inferred_ret = make_union_type(reg, concrete_returns[:])
		} else if len(return_types) > 0 && len(concrete_returns) == 0 {
			// All returns are Unknown (purely recursive with no base case typed)
			inferred_ret = TYPE_UNKNOWN
		}
		if inferred_ret != TYPE_UNKNOWN {
			result.inferred_returns[cfg.scope_id] = inferred_ret
		}
	}
}

// T010: Check if caller-provided type conflicts with body-inferred param type
check_caller_conflict :: proc(
	arg: ^parser.Arg,
	idx: int,
	scope: ^binder.Scope,
	entry_env: ^Type_Env,
	caller_param_types: map[int]Type_ID,
	reg: ^Type_Registry,
	diagnostics: ^[dynamic]core.Diagnostic,
	file_path: string,
) {
	if arg.arg == "self" || arg.arg == "cls" { return }
	if arg.annotation != nil { return } // annotated params don't need inference conflict check
	caller_t, has_ct := caller_param_types[idx]
	if !has_ct { return }
	if caller_t == TYPE_UNKNOWN || caller_t == TYPE_ANY { return }
	sym_id, has_sym := scope.symbols[arg.arg]
	if !has_sym { return }
	param_t, has_pt := entry_env.types[sym_id]
	if !has_pt { return }
	if param_t == TYPE_UNKNOWN || param_t == TYPE_ANY { return }
	if !is_assignable(reg, caller_t, param_t) {
		// Deduplicate: skip if T010 already emitted for this location
		for &d in diagnostics {
			if d.code == "T010" && d.location.line == int(arg.loc.line) && d.location.column == int(arg.loc.col) {
				return
			}
		}
		emit_diagnostic_raw(diagnostics, file_path, arg.loc, "T010", .Warning,
			"Conflicting type constraints",
			fmt.tprintf("Parameter '%s' inferred as '%s' from body but called with '%s'",
				arg.arg, type_to_string(reg, param_t), type_to_string(reg, caller_t)),
			"Check call sites or add type annotation")
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

		// Type alias fallback: if RHS produced Unknown and looks like a type expression,
		// try resolve_annotation (handles list[float], dict[str, int], etc.)
		if rhs_type == TYPE_UNKNOWN && s.value != nil {
			alias_type := resolve_annotation(s.value, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
			if alias_type != TYPE_UNKNOWN {
				rhs_type = alias_type
			}
		}

		// Check Final reassignment
		for target in s.targets {
			if name, ok := target.(^parser.Name_Expr); ok {
				if sym_id, ref_ok := binder.get_ref(ctx.bind_result, rawptr(name)); ref_ok {
					if ctx.final_vars != nil && sym_id in ctx.final_vars {
						emit_diagnostic(ctx, s.loc, "T012", .Error,
							"Cannot assign to final variable",
							fmt.tprintf("'%s' is declared as Final and cannot be reassigned", name.id),
							"Remove the reassignment or remove the Final annotation")
					}
				}
			}
		}

		// Check reassignment against declared annotation type
		if rhs_type != TYPE_UNKNOWN && rhs_type != TYPE_ANY {
			for target in s.targets {
				if name, ok := target.(^parser.Name_Expr); ok {
					// Skip self-assignment (x = x)
					if rhs_name, rhs_ok := s.value.(^parser.Name_Expr); rhs_ok {
						if rhs_name.id == name.id { continue }
					}
					if sym_id, ref_ok := binder.get_ref(ctx.bind_result, rawptr(name)); ref_ok {
						if declared, found := ctx.declared_types[sym_id]; found {
							if declared != TYPE_ANY && !_is_any_type(declared, ctx.reg) {
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
		}
		// Track inferred types for reassignment checking
		// Two patterns: Instance_Type from constructor calls, primitives from literals
		if rhs_type != TYPE_UNKNOWN && rhs_type != TYPE_ANY &&
		   !_is_any_type(rhs_type, ctx.reg) && len(s.targets) == 1 {
			if name, ok := s.targets[0].(^parser.Name_Expr); ok {
				if len(name.id) > 0 && name.id[0] != '_' {
					if sym_id, ref_ok := binder.get_ref(ctx.bind_result, rawptr(name)); ref_ok {
						if sym_id not_in ctx.declared_types {
							should_track := false
							// Pattern 1: Instance_Type from constructor Call_Expr
							rhs_t := get_type(ctx.reg, rhs_type)
							if _, is_instance := rhs_t.info.(Instance_Type); is_instance {
								if _, is_call := s.value.(^parser.Call_Expr); is_call {
									should_track = true
								}
							}
							// Pattern 2: Primitive from literal — DISABLED (creates too many FPs)
							// mypy only tracks in typed functions with specific rules
							// that are too complex to replicate without full mypy config support
							if should_track {
								ctx.declared_types[sym_id] = rhs_type
							}
						}
					}
				}
			}
		}

		for target in s.targets {
			assign_target(target, rhs_type, ctx)
		}
		// Register functional NamedTuple in class_types for isinstance support
		if rhs_type != TYPE_UNKNOWN && len(s.targets) == 1 {
			if name, ok := s.targets[0].(^parser.Name_Expr); ok {
				if sym_id, ref_ok := binder.get_ref(ctx.bind_result, rawptr(name)); ref_ok {
					rt := get_type(ctx.reg, rhs_type)
					if rt != nil {
						if _, is_class := rt.info.(Class_Type); is_class {
							ctx.reg.class_types[qualify(ctx.reg, sym_id)] = rhs_type
						}
					}
				}
			}
		}
		// GroupBy state recording: result = df.groupby("key")
		// Record source DataFrame + group key for column-aware aggregation
		if len(s.targets) == 1 {
			if name, ok := s.targets[0].(^parser.Name_Expr); ok {
				if sym_id, ref_ok := binder.get_ref(ctx.bind_result, rawptr(name)); ref_ok {
					if call, call_ok := s.value.(^parser.Call_Expr); call_ok {
						if attr, attr_ok := call.func.(^parser.Attribute_Expr); attr_ok {
							if attr.attr == "groupby" {
								// Check if receiver is a DataFrame
								recv_type := TYPE_UNKNOWN
								if recv_name, rn_ok := attr.value.(^parser.Name_Expr); rn_ok {
									if recv_sym, rsym_ok := binder.get_ref(ctx.bind_result, rawptr(recv_name)); rsym_ok {
										if rt, rt_found := ctx.env.types[recv_sym]; rt_found {
											recv_type = rt
										}
									}
								}
								if recv_type != TYPE_UNKNOWN {
									rt := get_type(ctx.reg, recv_type)
									if rt != nil {
										#partial switch _ in rt.info {
										case DataFrame_Type:
											// Extract group key from first arg
											if len(call.args) >= 1 {
												if c, c_ok := call.args[0].(^parser.Constant_Expr); c_ok {
													if key_str, ks_ok := c.value.(string); ks_ok {
														ctx.groupby_sources[sym_id] = GroupBy_Info{
															df_type   = recv_type,
															group_key = key_str,
														}
													}
												}
											}
										}
									}
								}
							}
						}
					}
				}
			}
		}
		// DataFrame column assignment: df["col"] = expr → update df's type
		for target in s.targets {
			if sub, ok := target.(^parser.Subscript_Expr); ok {
				if name, name_ok := sub.value.(^parser.Name_Expr); name_ok {
					if sym_id, ref_ok := binder.get_ref(ctx.bind_result, rawptr(name)); ref_ok {
						if cur_type, found := ctx.env.types[sym_id]; found {
							cur_t := get_type(ctx.reg, cur_type)
							if cur_t != nil {
								#partial switch df_info in cur_t.info {
								case DataFrame_Type:
									// Get column name from subscript key
									if key, key_ok := sub.slice.(^parser.Constant_Expr); key_ok {
										if col_name, str_ok := key.value.(string); str_ok {
											// Build new columns map with added/updated column
											new_cols := make(map[string]Type_ID, len(df_info.columns) + 1, ctx.reg.allocator)
											for cn, ct in df_info.columns { new_cols[cn] = ct }
											// Determine element type for the new column
											elem_type := rhs_type
											et := get_type(ctx.reg, rhs_type)
											if et != nil {
												#partial switch si in et.info {
												case Series_Type: elem_type = si.element
												case List_Type:   elem_type = si.element
												}
											}
											new_cols[col_name] = elem_type
											ctx.env.types[sym_id] = make_dataframe_type(ctx.reg, new_cols)
										}
									}
								case Dict_Type:
									// §3.5: dict["key"] = val → accumulate into TypedDict
									if key, key_ok := sub.slice.(^parser.Constant_Expr); key_ok {
										if key_name, str_ok := key.value.(string); str_ok {
											new_fields := make(map[string]Type_ID, 4, ctx.reg.allocator)
											new_fields[key_name] = rhs_type
											ctx.env.types[sym_id] = make_typeddict_type(ctx.reg, name.id, new_fields, true)
										}
									}
								case TypedDict_Type:
									// §3.5: existing TypedDict + new key → accumulate
									if key, key_ok := sub.slice.(^parser.Constant_Expr); key_ok {
										if key_name, str_ok := key.value.(string); str_ok {
											new_fields := make(map[string]Type_ID, len(df_info.fields) + 1, ctx.reg.allocator)
											for fn, ft in df_info.fields { new_fields[fn] = ft }
											new_fields[key_name] = rhs_type
											ctx.env.types[sym_id] = make_typeddict_type(ctx.reg, df_info.name, new_fields, df_info.total)
										}
									}
							}
						}
					}
				}
			}
		}
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

		// Detect Final[T] annotation — mark variable as immutable
		if is_final_annotation(s.annotation, ctx.bind_result) {
			if name, ok := s.target.(^parser.Name_Expr); ok {
				if sym_id, ref_ok := binder.get_ref(ctx.bind_result, rawptr(name)); ref_ok {
					ctx.final_vars[sym_id] = true
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

			if declared_return != TYPE_UNKNOWN && !_is_any_type(declared_return, ctx.reg) &&
			   ret_type != TYPE_UNKNOWN && !_is_any_type(ret_type, ctx.reg) {
				if !is_assignable(ctx.reg, ret_type, declared_return) {
					// Don't flag when returning to a Protocol — structural matching
					// may fail during function body check due to class scan ordering
					dr := get_type(ctx.reg, declared_return)
					_, is_proto := dr.info.(Protocol_Type)
					if !is_proto {
						emit_diagnostic(ctx, s.loc, "T003", .Error,
							"Incompatible return value type",
							fmt_type_mismatch(ret_type, declared_return, ctx.reg),
							"Change the return value or the return annotation")
					}
				}
			}
		} else {
			append(return_types, TYPE_NONE)
			// Bare "return" in non-None function
			if declared_return != TYPE_UNKNOWN && declared_return != TYPE_NONE &&
			   !_is_any_type(declared_return, ctx.reg) &&
			   !is_assignable(ctx.reg, TYPE_NONE, declared_return) {
				emit_diagnostic(ctx, s.loc, "T003", .Error,
					"Return value expected",
					fmt.tprintf("Function declared to return '%s' but returns None",
						type_to_string(ctx.reg, declared_return)),
					"Add a return value or change the return annotation to Optional")
			}
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
		// Check Final reassignment via augmented assignment (x += 1 where x is Final)
		if name, ok := s.target.(^parser.Name_Expr); ok {
			if sym_id, ref_ok := binder.get_ref(ctx.bind_result, rawptr(name)); ref_ok {
				if ctx.final_vars != nil && sym_id in ctx.final_vars {
					emit_diagnostic(ctx, s.loc, "T012", .Error,
						"Cannot assign to final variable",
						fmt.tprintf("'%s' is declared as Final and cannot be reassigned", name.id),
						"Remove the reassignment or remove the Final annotation")
				}
			}
		}
		lhs_type := infer_expr(s.target, ctx)
		rhs_type := infer_expr(s.value, ctx)
		result_type := infer_binop(s.op, lhs_type, rhs_type, ctx.reg)
		if result_type == TYPE_UNKNOWN && lhs_type != TYPE_UNKNOWN && rhs_type != TYPE_UNKNOWN {
			emit_diagnostic(ctx, s.loc, "T005", .Error,
				"Unsupported operand types",
				fmt_binop_error(s.op, lhs_type, rhs_type, ctx.reg),
				"Check operand types")
		}
		// Check augmented result against declared type (x: int; x += "str" → T001)
		if result_type != TYPE_UNKNOWN && result_type != TYPE_ANY {
			if name, ok := s.target.(^parser.Name_Expr); ok {
				if sym_id, ref_ok := binder.get_ref(ctx.bind_result, rawptr(name)); ref_ok {
					if declared, found := ctx.declared_types[sym_id]; found {
						if declared != TYPE_ANY && !_is_any_type(declared, ctx.reg) {
							if !is_assignable(ctx.reg, result_type, declared) {
								emit_diagnostic(ctx, s.loc, "T001", .Error,
									"Incompatible types in assignment",
									fmt_type_mismatch(result_type, declared, ctx.reg),
									"Check operand types for augmented assignment")
							}
						}
					}
				}
			}
		}
		assign_target(s.target, result_type, ctx)

	case ^parser.For_Stmt:
		iter_type := infer_expr(s.iter, ctx)
		// Check if iter expression is iterable
		if iter_type != TYPE_UNKNOWN && iter_type != TYPE_ANY &&
		   !_is_any_type(iter_type, ctx.reg) {
			switch iter_type {
			case TYPE_INT, TYPE_FLOAT, TYPE_BOOL, TYPE_NONE:
				emit_diagnostic(ctx, s.loc, "T005", .Error,
					"Not iterable",
					fmt.tprintf("'%s' is not iterable", type_to_string(ctx.reg, iter_type)),
					"Use a list, tuple, or other iterable")
			}
		}
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
		// assert isinstance(x, T) → narrow x to T in subsequent code
		apply_assert_narrowing(s.test, ctx)

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
		// Merge attribute narrowing types
		for key, type_id in pred_env.attr_types {
			if existing, ok := env.attr_types[key]; ok {
				if existing != type_id {
					members := [2]Type_ID{existing, type_id}
					env.attr_types[key] = make_union_type(reg, members[:])
				}
			} else {
				if env.attr_types == nil {
					env.attr_types = make(map[u64]Type_ID, 4, reg.allocator)
				}
				env.attr_types[key] = type_id
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
		// Lazily init attr_types when an attribute guard needs it
		if len(guard.attr_name) > 0 && env.attr_types == nil {
			if guard.true_block == block_id || guard.false_block == block_id {
				env.attr_types = make(map[u64]Type_ID, 4, reg.allocator)
			}
		}
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
	is_attr := len(guard.attr_name) > 0
	#partial switch guard.kind {
	case .Is_Instance, .Is_Not_Instance, .Type_Is, .Type_Is_Not:
		// Narrow to the guard type. Inverted kinds (Is_Not_Instance) come from
		// unary `not` with block swap — double inversion cancels, same semantics.
		narrow_type := resolve_isinstance_type(guard.type_expr, reg, bind_result, builtins)
		if narrow_type != TYPE_UNKNOWN {
			if is_attr {
				key := attr_narrow_key(guard.symbol_id, guard.attr_name)
				env.attr_types[key] = narrow_type
			} else {
				env.types[guard.symbol_id] = narrow_type
			}
		}
	case .Is_None, .Is_Not_None:
		if is_attr {
			key := attr_narrow_key(guard.symbol_id, guard.attr_name)
			env.attr_types[key] = TYPE_NONE
		} else {
			env.types[guard.symbol_id] = TYPE_NONE
		}
	case .Is_Truthy, .Is_Falsy:
		if is_attr {
			key := attr_narrow_key(guard.symbol_id, guard.attr_name)
			current, ok := env.attr_types[key]
			if !ok {
				// Get static attribute type from object
				obj_type, obj_ok := env.types[guard.symbol_id]
				if obj_ok {
					current = lookup_attribute(obj_type, guard.attr_name, reg)
					ok = current != TYPE_UNKNOWN
				}
			}
			if ok {
				env.attr_types[key] = remove_none(reg, current)
			}
		} else {
			current, ok := env.types[guard.symbol_id]
			if ok {
				env.types[guard.symbol_id] = remove_none(reg, current)
			}
		}
	case .Type_Guard, .Type_Is_Guard:
		// TypeGuard/TypeIs function call — look up target type from registry
		func_sym := binder.Symbol_ID(guard.resolved_type)
		if target, has_target := reg.typeguard_targets[func_sym]; has_target {
			env.types[guard.symbol_id] = target
		}
		if target, has_target := reg.typeis_targets[func_sym]; has_target {
			env.types[guard.symbol_id] = target
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
	is_attr := len(guard.attr_name) > 0
	#partial switch guard.kind {
	case .Is_Instance, .Is_Not_Instance, .Type_Is, .Type_Is_Not:
		// Subtract the guard type. Inverted kinds come from unary `not`
		// with block swap — double inversion cancels, same semantics.
		narrow_type := resolve_isinstance_type(guard.type_expr, reg, bind_result, builtins)
		if is_attr {
			key := attr_narrow_key(guard.symbol_id, guard.attr_name)
			current, ok := env.attr_types[key]
			if !ok {
				obj_type, obj_ok := env.types[guard.symbol_id]
				if obj_ok {
					current = lookup_attribute(obj_type, guard.attr_name, reg)
					ok = current != TYPE_UNKNOWN
				}
			}
			if ok && narrow_type != TYPE_UNKNOWN {
				env.attr_types[key] = subtract_type(reg, current, narrow_type)
			}
		} else {
			current, ok := env.types[guard.symbol_id]
			if ok && narrow_type != TYPE_UNKNOWN {
				env.types[guard.symbol_id] = subtract_type(reg, current, narrow_type)
			}
		}
	case .Is_None, .Is_Not_None:
		if is_attr {
			key := attr_narrow_key(guard.symbol_id, guard.attr_name)
			// Get static attribute type and remove None
			obj_type, obj_ok := env.types[guard.symbol_id]
			if obj_ok {
				attr_type := lookup_attribute(obj_type, guard.attr_name, reg)
				if attr_type != TYPE_UNKNOWN {
					env.attr_types[key] = remove_none(reg, attr_type)
				}
			}
		} else {
			current, ok := env.types[guard.symbol_id]
			if ok {
				env.types[guard.symbol_id] = remove_none(reg, current)
			}
		}
	case .Is_Truthy, .Is_Falsy:
		// In false branch of truthiness — could be None/False/0/empty
		// Conservative: don't narrow
		break
	case .Type_Guard, .Type_Is_Guard:
		// TypeGuard: no narrowing in false branch (by spec)
		// TypeIs (PEP 742): subtract the target type in false branch
		func_sym := binder.Symbol_ID(guard.resolved_type)
		if target, has_target := reg.typeis_targets[func_sym]; has_target {
			current, ok := env.types[guard.symbol_id]
			if ok && target != TYPE_UNKNOWN {
				env.types[guard.symbol_id] = subtract_type(reg, current, target)
			}
		}
		// TypeGuard functions (not in typeis_targets): no narrowing — falls through
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

// ==================== Assert Narrowing ====================

// assert isinstance(x, T) → narrow x to T; assert x is not None → remove None
apply_assert_narrowing :: proc(test: parser.Expr, ctx: ^Infer_Context) {
	if test == nil { return }
	#partial switch e in test {
	case ^parser.Call_Expr:
		// assert isinstance(x, T)
		if name, ok := e.func.(^parser.Name_Expr); ok && name.id == "isinstance" {
			if len(e.args) >= 2 {
				if var_name, vok := e.args[0].(^parser.Name_Expr); vok {
					if sym_id, rok := binder.get_ref(ctx.bind_result, rawptr(var_name)); rok {
						narrow_type := resolve_isinstance_type(e.args[1], ctx.reg, ctx.bind_result, ctx.builtins)
						if narrow_type != TYPE_UNKNOWN {
							ctx.env.types[sym_id] = narrow_type
						}
					}
				}
			}
		}
	case ^parser.Compare_Expr:
		// assert x is not None
		if len(e.ops) == 1 && e.ops[0] == .Is_Not && len(e.comparators) == 1 {
			if c, cok := e.comparators[0].(^parser.Constant_Expr); cok {
				if _, is_none := c.value.(parser.Const_None); is_none {
					if var_name, vok := e.left.(^parser.Name_Expr); vok {
						if sym_id, rok := binder.get_ref(ctx.bind_result, rawptr(var_name)); rok {
							if cur, has := ctx.env.types[sym_id]; has {
								ctx.env.types[sym_id] = remove_none(ctx.reg, cur)
							}
						}
					}
				}
			}
		}
	}
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

has_final_decorator :: proc(decorators: []parser.Expr, bind_result: ^binder.Bind_Result) -> bool {
	for dec in decorators {
		#partial switch d in dec {
		case ^parser.Name_Expr:
			if orig, is_typing := bind_result.typing_names[d.id]; is_typing && orig == "final" {
				return true
			}
			if d.id == "final" { return true }
		case ^parser.Attribute_Expr:
			if d.attr == "final" { return true }
		}
	}
	return false
}

has_abstractmethod_decorator :: proc(decorators: []parser.Expr) -> bool {
	for dec in decorators {
		#partial switch d in dec {
		case ^parser.Name_Expr:
			if d.id == "abstractmethod" { return true }
		case ^parser.Attribute_Expr:
			if d.attr == "abstractmethod" { return true }
		}
	}
	return false
}

// Register PEP 695 type parameters as TypeVars in the environment
_register_type_params :: proc(type_params: []parser.Type_Param, ctx: ^Infer_Context) {
	if len(type_params) == 0 { return }
	for tp in type_params {
		name: string
		loc: parser.Src_Loc
		bound_expr: parser.Expr
		#partial switch t in tp {
		case ^parser.Type_Var_Param:
			name = t.name
			loc = t.loc
			bound_expr = t.bound
		case ^parser.Param_Spec_Param:
			name = t.name
			loc = t.loc
		case ^parser.Type_Var_Tuple_Param:
			name = t.name
			loc = t.loc
		}
		if name == "" { continue }
		sym_id := find_symbol_for_name(name, loc, ctx.bind_result)
		if sym_id != binder.INVALID_SYMBOL {
			bound := TYPE_UNKNOWN
			if bound_expr != nil {
				bound = resolve_annotation(bound_expr, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
			}
			tv := register_type(ctx.reg, TypeVar_Type{name = name, bound = bound})
			ctx.env.types[sym_id] = tv
		}
	}
}

build_func_type :: proc(fd: ^parser.Func_Def, ctx: ^Infer_Context) -> Type_ID {
	// PEP 695: register type params as TypeVars in env before resolving annotations
	_register_type_params(fd.type_params, ctx)

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
	// 'self' is always stripped (only appears in methods by convention).
	// 'cls' is only stripped inside class scope — standalone functions with 'cls' param keep it.
	actual_params := params
	if !is_static && len(params) > 0 {
		if params[0].name == "self" {
			actual_params = params[1:]
		} else if params[0].name == "cls" {
			// Only strip 'cls' when inside a class scope or method context
			is_in_class := ctx.current_class != INVALID_TYPE
			if !is_in_class {
				scope := binder.result_get_scope(ctx.bind_result, ctx.scope_id)
				if scope != nil && scope.kind == .Class { is_in_class = true }
			}
			if is_in_class {
				actual_params = params[1:]
			}
		}
	}

	// Set class context for Self resolution in return annotation
	saved_resolve_class := ctx.reg.current_resolve_class
	if ctx.current_class != INVALID_TYPE {
		ctx.reg.current_resolve_class = ctx.current_class
	} else {
		// Check if we're inside a class scope (Func_Def processed during class body)
		scope := binder.result_get_scope(ctx.bind_result, ctx.scope_id)
		if scope != nil && scope.kind == .Class {
			for _, ct_id in ctx.reg.class_types {
				ct := get_type(ctx.reg, ct_id)
				#partial switch cls in ct.info {
				case Class_Type:
					if cls.scope_id == scope.id {
						ctx.reg.current_resolve_class = ct_id
					}
				}
				if ctx.reg.current_resolve_class != saved_resolve_class { break }
			}
		}
	}
	ret_type := resolve_annotation(fd.returns, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
	ctx.reg.current_resolve_class = saved_resolve_class

	// Detect TypeGuard[T] / TypeIs[T] return annotation → store target for guard narrowing
	if fd.returns != nil {
		if sub, sub_ok := fd.returns.(^parser.Subscript_Expr); sub_ok {
			base_name := get_annotation_name(sub.value)
			if orig, orig_ok := ctx.bind_result.typing_names[base_name]; orig_ok {
				if orig == "TypeGuard" || orig == "TypeIs" {
					target := resolve_annotation(sub.slice, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
					if target != TYPE_UNKNOWN {
						scope := binder.result_get_scope(ctx.bind_result, ctx.scope_id)
						if scope != nil {
							if func_sym, has_sym := scope.symbols[fd.name]; has_sym {
								if orig == "TypeIs" {
									ctx.reg.typeis_targets[func_sym] = target
								} else {
									ctx.reg.typeguard_targets[func_sym] = target
								}
							}
						}
					}
				}
			}
		}
	}

	return make_callable_type(ctx.reg, actual_params, ret_type)
}

build_async_func_type :: proc(fd: ^parser.Async_Func_Def, ctx: ^Infer_Context) -> Type_ID {
	// PEP 695: register type params as TypeVars in env before resolving annotations
	_register_type_params(fd.type_params, ctx)

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

	// Check for special typing bases: TypedDict, Protocol, Enum
	is_typeddict := false
	is_protocol := false
	is_enum := false
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
		// Enum detection — matches Enum, IntEnum, StrEnum, Flag, IntFlag
		if base_name == "Enum" || base_name == "IntEnum" || base_name == "StrEnum" ||
		   base_name == "Flag" || base_name == "IntFlag" {
			is_enum = true
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
		// Qualified lookup — file_id makes keys globally unique, no name verification needed
		if existing, found := ctx.reg.class_types[qualify(ctx.reg, sym_id)]; found {
			class_type_id = existing
		} else {
			class_type_id = register_type(ctx.reg, Class_Type{
				name      = cd.name,
				symbol_id = sym_id,
				scope_id  = scope_id,
			})
		}
		ctx.reg.class_types[qualify(ctx.reg, sym_id)] = class_type_id
	} else {
		class_type_id = register_type(ctx.reg, Class_Type{
			name      = cd.name,
			symbol_id = sym_id,
			scope_id  = scope_id,
		})
	}

	// Check for duplicate base classes
	{
		seen_bases := make(map[string]bool, 4, ctx.reg.allocator)
		for base in cd.bases {
			base_name := ""
			#partial switch b in base {
			case ^parser.Name_Expr: base_name = b.id
			case ^parser.Subscript_Expr: base_name = get_annotation_name(b.value)
			}
			if len(base_name) > 0 && base_name != "Generic" && base_name != "Protocol" {
				if base_name in seen_bases {
					emit_diagnostic(ctx, cd.loc, "T015", .Error,
						"Duplicate base class",
						fmt.tprintf("'%s' is listed as a base class more than once", base_name),
						"Remove the duplicate base class")
				}
				seen_bases[base_name] = true
			}
		}
	}

	// Resolve base classes, detecting Generic[T] for type_params
	bases_dyn := make([dynamic]Type_ID, 0, len(cd.bases), ctx.reg.allocator)
	type_params_dyn := make([dynamic]Type_ID, 0, 4, ctx.reg.allocator)
	has_mapping_base := false
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
		// Detect Mapping/MutableMapping/dict base by AST name
		// (typing.MutableMapping resolves to TYPE_UNKNOWN since typing module isn't fully modeled)
		base_name_str := ""
		#partial switch bn in base {
		case ^parser.Name_Expr:
			base_name_str = bn.id
		case ^parser.Subscript_Expr:
			base_name_str = get_annotation_name(bn.value)
		case ^parser.Attribute_Expr:
			base_name_str = bn.attr
		}
		if base_name_str == "Mapping" || base_name_str == "MutableMapping" || base_name_str == "dict" {
			has_mapping_base = true
		}
		append(&bases_dyn, infer_expr(base, ctx))
	}
	bases := make([]Type_ID, len(bases_dyn), ctx.reg.allocator)
	copy(bases, bases_dyn[:])

	// Check if any base class is @final (cannot subclass)
	for base_type_id in bases {
		base_t := get_type(ctx.reg, base_type_id)
		#partial switch base_cls in base_t.info {
		case Class_Type:
			if base_cls.is_final {
				emit_diagnostic(ctx, cd.loc, "T012", .Error,
					"Cannot inherit from final class",
					fmt.tprintf("'%s' is declared as @final and cannot be subclassed", base_cls.name),
					"Remove the @final decorator from the base class or don't inherit from it")
			}
		}
	}

	// PEP 695 type params fallback (if no Generic[T] base found)
	if len(type_params_dyn) == 0 && len(cd.type_params) > 0 {
		for tp in cd.type_params {
			#partial switch t in tp {
			case ^parser.Type_Var_Param:
				bound := TYPE_UNKNOWN
				if t.bound != nil {
					bound = resolve_annotation(t.bound, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
				}
				tv := register_type(ctx.reg, TypeVar_Type{name = t.name, bound = bound})
				append(&type_params_dyn, tv)
			case ^parser.Param_Spec_Param:
				tv := register_type(ctx.reg, TypeVar_Type{name = t.name, bound = TYPE_UNKNOWN})
				append(&type_params_dyn, tv)
			case ^parser.Type_Var_Tuple_Param:
				tv := register_type(ctx.reg, TypeVar_Type{name = t.name, bound = TYPE_UNKNOWN})
				append(&type_params_dyn, tv)
			}
		}
	}

	type_params: []Type_ID
	if len(type_params_dyn) > 0 {
		type_params = make([]Type_ID, len(type_params_dyn), ctx.reg.allocator)
		copy(type_params, type_params_dyn[:])
	}

	// Build attrs from class body
	attrs := make(map[string]Type_ID, 16, ctx.reg.allocator)

	// Scan class body for method and attribute definitions
	// Set class context for Self resolution + cls stripping in method return annotations
	saved_resolve := ctx.reg.current_resolve_class
	saved_class := ctx.current_class
	ctx.reg.current_resolve_class = class_type_id
	ctx.current_class = class_type_id
	scan_class_body_attrs(cd.body, ctx, &attrs)
	ctx.reg.current_resolve_class = saved_resolve
	ctx.current_class = saved_class

	// Enum: inject standard attrs (name, value) available on all enum members
	if is_enum {
		attrs["name"] = TYPE_STR
		attrs["value"] = TYPE_ANY
		attrs["_name_"] = TYPE_STR
		attrs["_value_"] = TYPE_ANY
		attrs["_member_map_"] = TYPE_ANY
		attrs["_value2member_map_"] = TYPE_ANY
	}

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

	// Inject dict methods for classes inheriting from Mapping/MutableMapping/dict
	// This handles the case where the base type resolves to TYPE_UNKNOWN
	// (e.g., typing.MutableMapping not fully modeled)
	if has_mapping_base {
		_inject_dict_methods(&attrs, ctx.reg)
	}
	// (debug removed)

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
		// If any base is Any/Unknown, add **kwargs to accept additional args
		has_any_base := false
		for base_type_id in bases {
			if base_type_id == TYPE_ANY || base_type_id == TYPE_UNKNOWN ||
			   _is_any_type(base_type_id, ctx.reg) {
				has_any_base = true
				break
			}
		}
		if has_any_base {
			append(&init_params, Param_Type{name = "kwargs", type_id = TYPE_ANY, has_default = true, is_variadic = true})
		}
		attrs["__init__"] = make_callable_type(ctx.reg, init_params[:], TYPE_NONE)
		no_params := make([]Param_Type, 0, ctx.reg.allocator)
		attrs["__repr__"] = make_callable_type(ctx.reg, no_params, TYPE_STR)
		eq_params := make([]Param_Type, 1, ctx.reg.allocator)
		eq_params[0] = Param_Type{name = "other", type_id = TYPE_OBJECT}
		attrs["__eq__"] = make_callable_type(ctx.reg, eq_params, TYPE_BOOL)
	}

	// Detect @final class decorator
	class_is_final := has_final_decorator(cd.decorator_list, ctx.bind_result)

	// Collect abstract methods from this class body + inherited from bases
	abstract_meths := make(map[string]bool, 4, ctx.reg.allocator)
	// Inherit abstract methods from bases
	for base_type_id in bases {
		base_t := get_type(ctx.reg, base_type_id)
		#partial switch base_cls in base_t.info {
		case Class_Type:
			for name, is_abstract in base_cls.abstract_methods {
				if is_abstract {
					abstract_meths[name] = true
				}
			}
		}
	}
	// Scan body for @abstractmethod and concrete overrides
	for stmt in cd.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			if has_abstractmethod_decorator(s.decorator_list) {
				abstract_meths[s.name] = true
			} else if s.name in abstract_meths {
				// Concrete implementation overrides abstract
				delete_key(&abstract_meths, s.name)
			}
		case ^parser.Async_Func_Def:
			if has_abstractmethod_decorator(s.decorator_list) {
				abstract_meths[s.name] = true
			} else if s.name in abstract_meths {
				delete_key(&abstract_meths, s.name)
			}
		}
	}

	// Check @final method override: if parent has @final method, child can't override
	for stmt in cd.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			for base_type_id in bases {
				base_t := get_type(ctx.reg, base_type_id)
				#partial switch &base_cls in base_t.info {
				case Class_Type:
					// Check if base method was @final — we track via a naming convention
					// For now, check if the base class body had @final on this method
					// (tracked in the attrs — we don't store final method flags yet,
					//  but the base's scan would have set it)
				}
			}
		}
	}

	// Update placeholder with actual class data
	ct := get_type(ctx.reg, class_type_id)
	#partial switch &info in ct.info {
	case Class_Type:
		info.bases = bases
		info.attrs = attrs
		info.type_params = type_params
		info.is_final = class_is_final
		info.is_enum = is_enum
		info.abstract_methods = abstract_meths
	}

	return class_type_id
}

// TypedDict class syntax: class Movie(TypedDict): name: str; year: int
build_typeddict_class :: proc(cd: ^parser.Class_Def, ctx: ^Infer_Context, scope_id: binder.Scope_ID) -> Type_ID {
	fields := make(map[string]Type_ID, 16, ctx.reg.allocator)
	required_fields := make(map[string]bool, 16, ctx.reg.allocator)

	// Determine base total= value from class keywords
	total := true
	for kw in cd.keywords {
		if kw.arg == "total" {
			if c, ok := kw.value.(^parser.Constant_Expr); ok {
				if bval, bok := c.value.(bool); bok {
					total = bval
				}
			}
		}
	}

	for stmt in cd.body {
		#partial switch s in stmt {
		case ^parser.Ann_Assign:
			if name_expr, ok := s.target.(^parser.Name_Expr); ok {
				field_type := resolve_annotation(s.annotation, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
				fields[name_expr.id] = field_type
				// Detect Required[T] / NotRequired[T] wrappers
				is_required_override := is_required_annotation(s.annotation, ctx.bind_result)
				is_notrequired_override := is_notrequired_annotation(s.annotation, ctx.bind_result)
				if is_required_override {
					required_fields[name_expr.id] = true
				} else if is_notrequired_override {
					required_fields[name_expr.id] = false
				} else {
					// Default based on total
					required_fields[name_expr.id] = total
				}
			}
		}
	}

	sym_id := find_symbol_for_name(cd.name, cd.loc, ctx.bind_result)
	td_type_id := register_type(ctx.reg, TypedDict_Type{
		name            = cd.name,
		fields          = fields,
		total           = total,
		required_fields = required_fields,
	})

	if sym_id != binder.INVALID_SYMBOL {
		ctx.reg.class_types[qualify(ctx.reg, sym_id)] = td_type_id
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
		ctx.reg.class_types[qualify(ctx.reg, sym_id)] = proto_type_id
	}

	return proto_type_id
}

// Scan class body for method and attribute definitions, recursing into if/try/with blocks
scan_class_body_attrs :: proc(stmts: []parser.Stmt, ctx: ^Infer_Context, attrs: ^map[string]Type_ID) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			ft := build_func_type(s, ctx)
			// @property: store return type instead of callable (attribute access, not call)
			// @name.setter / @name.deleter: skip — keep the getter's return type
			is_property := false
			is_setter_or_deleter := false
			for dec in s.decorator_list {
				#partial switch d in dec {
				case ^parser.Name_Expr:
					if d.id == "property" { is_property = true }
				case ^parser.Attribute_Expr:
					if d.attr == "property" { is_property = true }
					if d.attr == "setter" || d.attr == "deleter" { is_setter_or_deleter = true }
				}
			}
			if is_setter_or_deleter {
				// Don't overwrite the property attr — getter's return type is correct
			} else if is_property {
				ft_info := get_type(ctx.reg, ft)
				#partial switch callable in ft_info.info {
				case Callable_Type:
					attrs[s.name] = callable.return_type
				case:
					attrs[s.name] = ft
				}
			} else {
				attrs[s.name] = ft
			}
			if s.name == "__init__" {
				scan_init_attrs(s, ctx, attrs)
			}
		case ^parser.Async_Func_Def:
			ft := build_async_func_type(s, ctx)
			// Same property/setter handling as sync methods
			is_property := false
			is_setter_or_deleter := false
			for dec in s.decorator_list {
				#partial switch d in dec {
				case ^parser.Name_Expr:
					if d.id == "property" { is_property = true }
				case ^parser.Attribute_Expr:
					if d.attr == "property" { is_property = true }
					if d.attr == "setter" || d.attr == "deleter" { is_setter_or_deleter = true }
				}
			}
			if is_setter_or_deleter {
				// skip
			} else if is_property {
				ft_info := get_type(ctx.reg, ft)
				#partial switch callable in ft_info.info {
				case Callable_Type:
					attrs[s.name] = callable.return_type
				case:
					attrs[s.name] = ft
				}
			} else {
				attrs[s.name] = ft
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
		case ^parser.Class_Def:
			// Nested class — register as attr (class type)
			nested_type := build_class_type(s, ctx)
			attrs[s.name] = nested_type
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

// Inject dict/mapping methods into a class's attrs map.
// Used when a class inherits from Mapping/MutableMapping/dict but the base type
// resolves to TYPE_UNKNOWN (e.g., typing.MutableMapping not fully modeled).
@(private = "file")
_inject_dict_methods :: proc(attrs: ^map[string]Type_ID, reg: ^Type_Registry) {
	no_params := make([]Param_Type, 0, reg.allocator)
	if "get" not_in attrs^ { attrs["get"] = make_callable_type(reg, make_params(reg, {TYPE_STR, TYPE_ANY}, {false, true}), TYPE_ANY) }
	if "pop" not_in attrs^ { attrs["pop"] = make_callable_type(reg, make_params(reg, {TYPE_STR, TYPE_ANY}, {false, true}), TYPE_ANY) }
	if "setdefault" not_in attrs^ { attrs["setdefault"] = make_callable_type(reg, make_params(reg, {TYPE_STR, TYPE_ANY}, {false, true}), TYPE_ANY) }
	if "keys" not_in attrs^ { attrs["keys"] = make_callable_type(reg, no_params, TYPE_ANY) }
	if "values" not_in attrs^ { attrs["values"] = make_callable_type(reg, no_params, TYPE_ANY) }
	if "items" not_in attrs^ { attrs["items"] = make_callable_type(reg, no_params, TYPE_ANY) }
	if "update" not_in attrs^ { attrs["update"] = make_callable_type(reg, make_params(reg, {TYPE_ANY}, {true}), TYPE_NONE) }
	if "copy" not_in attrs^ { attrs["copy"] = make_callable_type(reg, no_params, TYPE_ANY) }
	if "__contains__" not_in attrs^ { attrs["__contains__"] = make_callable_type(reg, make_params(reg, {TYPE_ANY}), TYPE_BOOL) }
	if "__len__" not_in attrs^ { attrs["__len__"] = make_callable_type(reg, no_params, TYPE_INT) }
	if "__getitem__" not_in attrs^ { attrs["__getitem__"] = make_callable_type(reg, make_params(reg, {TYPE_ANY}), TYPE_ANY) }
	if "__setitem__" not_in attrs^ { attrs["__setitem__"] = make_callable_type(reg, make_params(reg, {TYPE_ANY, TYPE_ANY}), TYPE_NONE) }
	if "__delitem__" not_in attrs^ { attrs["__delitem__"] = make_callable_type(reg, make_params(reg, {TYPE_ANY}), TYPE_NONE) }
	if "clear" not_in attrs^ { attrs["clear"] = make_callable_type(reg, no_params, TYPE_NONE) }
}

// Resolve a name to a param annotation type in __init__.
@(private = "file")
_resolve_param_type :: proc(name: string, fd: ^parser.Func_Def, ctx: ^Infer_Context) -> Type_ID {
	// Check args (regular params)
	for arg in fd.args.args {
		if arg.arg == name && arg.annotation != nil {
			return resolve_annotation(arg.annotation, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
		}
	}
	// Check posonlyargs
	for arg in fd.args.posonlyargs {
		if arg.arg == name && arg.annotation != nil {
			return resolve_annotation(arg.annotation, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
		}
	}
	// Check kwonlyargs
	for arg in fd.args.kwonlyargs {
		if arg.arg == name && arg.annotation != nil {
			return resolve_annotation(arg.annotation, ctx.reg, ctx.bind_result, ctx.builtins, ctx.env)
		}
	}
	return TYPE_UNKNOWN
}

// Try to resolve RHS type from param usage: param.method(), Constructor(param), etc.
@(private = "file")
_resolve_rhs_from_param :: proc(value: parser.Expr, fd: ^parser.Func_Def, ctx: ^Infer_Context) -> Type_ID {
	if value == nil { return TYPE_UNKNOWN }
	// param.method() — the base of a method call is a param
	#partial switch call in value {
	case ^parser.Call_Expr:
		if attr, ok := call.func.(^parser.Attribute_Expr); ok {
			if name, ok2 := attr.value.(^parser.Name_Expr); ok2 {
				return _resolve_param_type(name.id, fd, ctx)
			}
		}
	}
	// Attribute access on param: param.attr
	#partial switch attr in value {
	case ^parser.Attribute_Expr:
		if name, ok := attr.value.(^parser.Name_Expr); ok {
			return _resolve_param_type(name.id, fd, ctx)
		}
	}
	return TYPE_UNKNOWN
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
									val_type = _resolve_param_type(name.id, fd, ctx)
								}
								// Second try: self.x = param.method() — use param's type
								if val_type == TYPE_UNKNOWN {
									val_type = _resolve_rhs_from_param(s.value, fd, ctx)
								}
								// Fallback: infer from RHS expression
								if val_type == TYPE_UNKNOWN {
									val_type = infer_expr(s.value, ctx)
								}
								// Last resort for same-named param: self.method = method.upper()
								// Attr name matches a param → use param type
								if val_type == TYPE_UNKNOWN {
									val_type = _resolve_param_type(attr.attr, fd, ctx)
								}
							}
							// Don't overwrite a known type with TYPE_UNKNOWN
							if val_type != TYPE_UNKNOWN || attr.attr not_in attrs^ {
								attrs[attr.attr] = val_type
							}
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
							val_type := TYPE_UNKNOWN
							// Try param resolution first for Name_Expr values
							if name, ok3 := s.value.(^parser.Name_Expr); ok3 {
								val_type = _resolve_param_type(name.id, fd, ctx)
							}
							if val_type == TYPE_UNKNOWN {
								val_type = _resolve_rhs_from_param(s.value, fd, ctx)
							}
							if val_type == TYPE_UNKNOWN {
								val_type = infer_expr(s.value, ctx)
							}
							if val_type == TYPE_UNKNOWN {
								val_type = _resolve_param_type(attr.attr, fd, ctx)
							}
							// Don't overwrite a known type with TYPE_UNKNOWN.
							// Multiple branches may set the same attr — keep the resolved one.
							if val_type != TYPE_UNKNOWN || attr.attr not_in attrs^ {
								attrs[attr.attr] = val_type
							}
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
			// During re-inference: if RHS is UNKNOWN but constraints resolved a type, use it
			actual_type := type_id
			if actual_type == TYPE_UNKNOWN && ctx.resolved_types != nil {
				if rt, has_rt := ctx.resolved_types[sym_id]; has_rt {
					actual_type = rt
				}
			}
			ctx.env.types[sym_id] = actual_type
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
			// Skip if already registered (e.g., from imports) — qualified key makes this collision-free
			if sym_id != binder.INVALID_SYMBOL {
				if _, a := reg.class_types[qualify(reg, sym_id)]; a { continue }
			}
			scope_id := find_scope_for_def(s.name, s.loc, bind_result, .Class)
			class_type_id := register_type(reg, Class_Type{
				name      = s.name,
				symbol_id = sym_id,
				scope_id  = scope_id,
			})
			if sym_id != binder.INVALID_SYMBOL {
				reg.class_types[qualify(reg, sym_id)] = class_type_id
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
			// Set class context for Self resolution in method return annotations
			saved_class := reg.current_resolve_class
			class_scope_id := find_scope_for_def(s.name, s.loc, bind_result, .Class)
			if class_scope_id != binder.INVALID_SCOPE {
				for _, ct_id in reg.class_types {
					ct := get_type(reg, ct_id)
					#partial switch cls in ct.info {
					case Class_Type:
						if cls.scope_id == class_scope_id {
							reg.current_resolve_class = ct_id
							break
						}
					}
					if reg.current_resolve_class != saved_class { break }
				}
			}
			collect_func_return_types(s.body, bind_result, reg, builtins, out)
			reg.current_resolve_class = saved_class

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

// Extract Generator[Y, S, R] send types from function return annotations.
// For functions annotated with -> Generator[Y, S, R] or -> AsyncGenerator[Y, S],
// stores the SendType (S) per scope so yield expressions can return it.
collect_generator_send_types :: proc(
	stmts: []parser.Stmt,
	bind_result: ^binder.Bind_Result,
	reg: ^Type_Registry,
	builtins: ^Builtin_Names,
	out: ^map[binder.Scope_ID]Type_ID,
) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			_extract_generator_send(s.returns, s.name, s.loc, bind_result, reg, builtins, out)
			collect_generator_send_types(s.body, bind_result, reg, builtins, out)
		case ^parser.Async_Func_Def:
			_extract_generator_send(s.returns, s.name, s.loc, bind_result, reg, builtins, out)
			collect_generator_send_types(s.body, bind_result, reg, builtins, out)
		case ^parser.Class_Def:
			collect_generator_send_types(s.body, bind_result, reg, builtins, out)
		case ^parser.If_Stmt:
			collect_generator_send_types(s.body, bind_result, reg, builtins, out)
			collect_generator_send_types(s.orelse, bind_result, reg, builtins, out)
		case ^parser.For_Stmt:
			collect_generator_send_types(s.body, bind_result, reg, builtins, out)
		case ^parser.While_Stmt:
			collect_generator_send_types(s.body, bind_result, reg, builtins, out)
		case ^parser.Try_Stmt:
			collect_generator_send_types(s.body, bind_result, reg, builtins, out)
			for handler in s.handlers {
				collect_generator_send_types(handler.body, bind_result, reg, builtins, out)
			}
		}
	}
}

// Check if a return annotation is Generator[Y, S, R] or AsyncGenerator[Y, S]
// and extract the SendType into the output map.
_extract_generator_send :: proc(
	returns: parser.Expr,
	name: string,
	loc: parser.Src_Loc,
	bind_result: ^binder.Bind_Result,
	reg: ^Type_Registry,
	builtins: ^Builtin_Names,
	out: ^map[binder.Scope_ID]Type_ID,
) {
	if returns == nil { return }
	sub, ok := returns.(^parser.Subscript_Expr)
	if !ok { return }

	base_name := get_annotation_name(sub.value)
	if len(base_name) == 0 { return }

	// Check if this is a typing.Generator or typing.AsyncGenerator
	// Two paths: (1) from typing import Generator → typing_names lookup
	//            (2) typing.Generator → Attribute_Expr with attr "Generator"/"AsyncGenerator"
	is_generator := false
	is_async_gen := false
	if orig, is_typing := bind_result.typing_names[base_name]; is_typing {
		is_generator = orig == "Generator"
		is_async_gen = orig == "AsyncGenerator"
	} else if attr, attr_ok := sub.value.(^parser.Attribute_Expr); attr_ok {
		// typing.Generator or typing.AsyncGenerator
		if mod, mod_ok := attr.value.(^parser.Name_Expr); mod_ok {
			if mod.id == "typing" || mod.id == "typing_extensions" {
				is_generator = attr.attr == "Generator"
				is_async_gen = attr.attr == "AsyncGenerator"
			}
		}
	}
	if !is_generator && !is_async_gen { return }

	// Extract type params from the subscript slice
	// Generator[Y, S, R] — S is index 1
	// AsyncGenerator[Y, S] — S is index 1
	tup, tup_ok := sub.slice.(^parser.Tuple_Expr)
	if !tup_ok { return }

	send_idx := 1
	if is_generator && len(tup.elts) >= 2 {
		send_type := resolve_annotation(tup.elts[send_idx], reg, bind_result, builtins)
		if send_type != TYPE_UNKNOWN {
			scope_id := find_scope_for_def(name, loc, bind_result, .Function)
			if scope_id != binder.INVALID_SCOPE {
				out[scope_id] = send_type
			}
		}
	} else if is_async_gen && len(tup.elts) >= 2 {
		send_type := resolve_annotation(tup.elts[send_idx], reg, bind_result, builtins)
		if send_type != TYPE_UNKNOWN {
			scope_id := find_scope_for_def(name, loc, bind_result, .Function)
			if scope_id != binder.INVALID_SCOPE {
				out[scope_id] = send_type
			}
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
		case ^parser.Assign:
			// Scan RHS for lambda expressions
			if s.value != nil {
				collect_lambda_args(s.value, bind_result, out)
			}
		case ^parser.Ann_Assign:
			if s.value != nil {
				collect_lambda_args(s.value, bind_result, out)
			}
		case ^parser.Expr_Stmt:
			if s.value != nil {
				collect_lambda_args(s.value, bind_result, out)
			}
		case ^parser.Return_Stmt:
			if s.value != nil {
				collect_lambda_args(s.value, bind_result, out)
			}
		}
	}
}

// Find lambda expressions in expression trees and register their args
collect_lambda_args :: proc(expr: parser.Expr, bind_result: ^binder.Bind_Result, out: ^map[binder.Scope_ID]^parser.Arguments) {
	if expr == nil { return }
	#partial switch e in expr {
	case ^parser.Lambda_Expr:
		// Find lambda scope by matching location
		for &scope in bind_result.scopes {
			if scope.kind == .Lambda && scope.loc.line == e.loc.line && scope.loc.col == e.loc.col {
				out[scope.id] = &e.args
				break
			}
		}
	case ^parser.Call_Expr:
		// Recurse into call args (lambda might be an argument)
		collect_lambda_args(e.func, bind_result, out)
		for arg in e.args { collect_lambda_args(arg, bind_result, out) }
		for &kw in e.keywords { collect_lambda_args(kw.value, bind_result, out) }
	case ^parser.If_Expr:
		collect_lambda_args(e.body, bind_result, out)
		collect_lambda_args(e.test, bind_result, out)
		collect_lambda_args(e.orelse, bind_result, out)
	case ^parser.Tuple_Expr:
		for el in e.elts { collect_lambda_args(el, bind_result, out) }
	case ^parser.List_Expr:
		for el in e.elts { collect_lambda_args(el, bind_result, out) }
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

			// §3.4: Check expr_types first (may have specialized return type)
			call_type := TYPE_UNKNOWN
			if spec_type, ok := result.expr_types[expr_to_rawptr(s.value)]; ok {
				if spec_type != TYPE_UNKNOWN && spec_type != TYPE_ANY {
					call_type = spec_type
				}
			}
			if call_type == TYPE_UNKNOWN {
				call_type = reinfer_call_return(s.value, result, bind_result, reg, builtins)
			}
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

				// §3.4: Check expr_types first (may have specialized return type)
				call_type := TYPE_UNKNOWN
				if spec_type, ok := result.expr_types[expr_to_rawptr(s.value)]; ok {
					if spec_type != TYPE_UNKNOWN && spec_type != TYPE_ANY {
						call_type = spec_type
					}
				}
				if call_type == TYPE_UNKNOWN {
					call_type = reinfer_call_return(s.value, result, bind_result, reg, builtins)
				}
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
	} else if attr, attr_ok := call.func.(^parser.Attribute_Expr); attr_ok {
		// Method call: obj.method() — resolve via object type → class → method callable
		obj_type, has_obj := result.expr_types[expr_to_rawptr(attr.value)]
		if !has_obj { return TYPE_UNKNOWN }

		// Unwrap Instance_Type → Class_Type
		class_type_id := TYPE_UNKNOWN
		t := get_type(reg, obj_type)
		#partial switch info in t.info {
		case Instance_Type:
			class_type_id = info.class_type
		}
		if class_type_id == TYPE_UNKNOWN { return TYPE_UNKNOWN }

		// Look up method in class attrs
		ct := get_type(reg, class_type_id)
		#partial switch cls in ct.info {
		case Class_Type:
			method_type_id, has_method := cls.attrs[attr.attr]
			if !has_method { return TYPE_UNKNOWN }
			mt := get_type(reg, method_type_id)
			#partial switch method_info in mt.info {
			case Callable_Type:
				return method_info.return_type
			}
		}
	}

	return TYPE_UNKNOWN
}

// ==================== §3.4 Call-Site Specialization ====================

// Per-call-site return type specialization for unannotated generic functions.
// After convergence establishes merged types, re-check each distinct arg pattern
// to get specialized return types. Overrides expr_types at each call site.
specialize_call_sites :: proc(
	result: ^Check_Result,
	bind_result: ^binder.Bind_Result,
	flow_result: ^flow.Flow_Result,
	call_sites: []Call_Site_Info,
	func_args_map: ^map[binder.Scope_ID]^parser.Arguments,
	builtins: ^Builtin_Names,
	mt: ^Builtin_Method_Table,
	file_path: string,
	shape_reg: ^Shape_Registry = nil,
	allocator: mem.Allocator = context.allocator,
	reg_override: ^Type_Registry = nil,
) {
	if len(call_sites) == 0 { return }

	// Group call sites by callee scope
	groups := make(map[binder.Scope_ID][dynamic]int, 8, allocator)
	for _, i in call_sites {
		scope := call_sites[i].callee_scope
		if scope not_in groups {
			groups[scope] = make([dynamic]int, 0, 4, allocator)
		}
		append(&groups[scope], i)
	}

	// Specialization cache: hash(scope, arg_types) → return type
	spec_cache := make(map[u64]Type_ID, 16, allocator)

	MAX_SPECIALIZATIONS :: 8

	for scope_id, indices in groups {
		if len(indices) < 2 { continue }

		// Collect distinct type patterns
		pattern_hashes := make(map[u64]bool, 8, allocator)
		for idx in indices {
			h := hash_type_pattern(call_sites[idx].callee_scope, call_sites[idx].arg_types)
			pattern_hashes[h] = true
		}
		if len(pattern_hashes) < 2 { continue }
		if len(pattern_hashes) > MAX_SPECIALIZATIONS { continue }

		// Find the CFG for this scope
		target_cfg: ^flow.CFG = nil
		for &cfg in flow_result.cfgs {
			if cfg.scope_id == scope_id {
				target_cfg = &cfg
				break
			}
		}
		if target_cfg == nil { continue }

		// Save state before specialization re-checks
		saved_return, had_return := result.inferred_returns[scope_id]
		diag_count := len(result.diagnostics)

		// Track which patterns we've already checked
		checked := make(map[u64]bool, 8, allocator)

		for idx in indices {
			h := hash_type_pattern(call_sites[idx].callee_scope, call_sites[idx].arg_types)
			if h in spec_cache || h in checked { continue }
			checked[h] = true

			// Build caller_param_types from this call's arg types
			cpt := make(map[int]Type_ID, 4, allocator)
			for t, param_idx in call_sites[idx].arg_types {
				if t != TYPE_UNKNOWN && t != TYPE_ANY {
					cpt[param_idx] = t
				}
			}
			if len(cpt) == 0 { continue }

			// Clear inferred_returns for this scope so re-check can set it
			delete_key(&result.inferred_returns, scope_id)

			// Look up const_map for this scope
			spec_cm: ^flow.Const_Map = nil
			if scope_cm, ok := &flow_result.const_maps[target_cfg.scope_id]; ok {
				spec_cm = scope_cm
			}

			// Re-check with this specific arg pattern
			check_scope(
				target_cfg,
				bind_result,
				flow_result,
				result           = result,
				builtins         = builtins,
				file_path        = file_path,
				declared_return  = TYPE_UNKNOWN,
				func_args_map    = func_args_map,
				reg_override     = reg_override,
				method_table     = mt,
				shape_reg        = shape_reg,
				const_map        = spec_cm,
				caller_param_types = cpt,
			)

			// Extract specialized return type
			if ret, ok := result.inferred_returns[scope_id]; ok {
				spec_cache[h] = ret
			}

			// Suppress duplicate diagnostics from re-check
			resize(&result.diagnostics, diag_count)
		}

		// Restore merged return type
		if had_return {
			result.inferred_returns[scope_id] = saved_return
		} else {
			delete_key(&result.inferred_returns, scope_id)
		}
	}

	// Apply specialized return types to call sites
	for &cs in call_sites {
		h := hash_type_pattern(cs.callee_scope, cs.arg_types)
		if ret, ok := spec_cache[h]; ok {
			result.expr_types[cs.call_expr] = ret
		}
	}

	// Set widened return type for each specialized function
	// (union of all specialized returns — for hover/reveal_type on the function itself)
	reg := reg_override if reg_override != nil else &result.registry
	scope_returns := make(map[binder.Scope_ID][dynamic]Type_ID, 4, allocator)
	for h, ret in spec_cache {
		// Find which scope this hash belongs to by checking call sites
		for &cs in call_sites {
			ch := hash_type_pattern(cs.callee_scope, cs.arg_types)
			if ch == h {
				if cs.callee_scope not_in scope_returns {
					scope_returns[cs.callee_scope] = make([dynamic]Type_ID, 0, 4, allocator)
				}
				append(&scope_returns[cs.callee_scope], ret)
				break
			}
		}
	}
	for scope_id, returns in scope_returns {
		if len(returns) == 1 {
			result.inferred_returns[scope_id] = returns[0]
		} else if len(returns) > 1 {
			result.inferred_returns[scope_id] = make_union_type(reg, returns[:])
		}
	}
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
		func_sym_id: binder.Symbol_ID
		found := false
		if scope.kind == .Lambda {
			// Lambda scopes have name "<lambda>" — match by def location
			for _, sym_id in parent.symbols {
				sym := binder.result_get_symbol(bind_result, sym_id)
				if sym != nil && sym.def_loc.line == scope.loc.line {
					func_sym_id = sym_id
					found = true
					break
				}
			}
		} else {
			func_sym_id, found = parent.symbols[scope.name]
		}
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

		// Also update the Class_Type attrs copy if this is a method.
		// build_func_type is called twice (check_stmt + scan_class_body),
		// producing different Type_IDs. Backfill must update BOTH.
		if parent != nil && parent.kind == .Class {
			// Find the class type and update its attrs entry
			for _, ct_id in reg.class_types {
				ct := get_type(reg, ct_id)
				#partial switch &cls in ct.info {
				case Class_Type:
					if cls.scope_id == parent.id {
						if attr_type_id, has_attr := cls.attrs[scope.name]; has_attr {
							attr_t := get_type(reg, attr_type_id)
							#partial switch &attr_info in attr_t.info {
							case Callable_Type:
								if attr_info.return_type == TYPE_UNKNOWN {
									attr_info.return_type = inferred_ret
								}
							}
						}
						break
					}
				}
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
