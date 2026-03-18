package checker

import "core:mem"
import parser "mimir:parser"
import binder "mimir:binder"
import flow   "mimir:flow"
import core   "mimir:core"

// ==================== Constraint Resolution ====================
//
// Resolves constraints for TYPE_UNKNOWN symbols by structural type inference:
// for each unknown symbol, intersect the types that satisfy ALL observed usage
// constraints. Example: x.split(",") + x.strip() → both satisfied by str → x: str

resolve_constraints :: proc(
	cs: ^Constraint_Set,
	method_table: ^Builtin_Method_Table,
	reg: ^Type_Registry,
	allocator: mem.Allocator,
) -> map[binder.Symbol_ID]Type_ID {
	result := make(map[binder.Symbol_ID]Type_ID, 8, allocator)

	for &var_info in cs.vars {
		if var_info.forward_type != TYPE_UNKNOWN { continue }

		constraint_indices, ok := cs.var_constraints[var_info.id]
		if !ok || len(constraint_indices) == 0 { continue }

		// Collect candidate type sets from each constraint
		first := true
		candidates := make(map[Type_ID]bool, 16, allocator)

		for ci in constraint_indices {
			c := cs.constraints[ci]
			matches := resolve_single_constraint(c, method_table, reg, allocator)
			if len(matches) == 0 { continue }

			if first {
				// Initialize with first constraint's matches
				for t in matches { candidates[t] = true }
				first = false
			} else {
				// Intersect: keep only types that appear in both
				to_remove := make([dynamic]Type_ID, 0, 8, allocator)
				for t in candidates {
					found := false
					for m in matches {
						if m == t { found = true; break }
					}
					if !found { append(&to_remove, t) }
				}
				for t in to_remove { delete_key(&candidates, t) }
			}
		}

		if len(candidates) == 0 { continue }

		// Pick the resolved type
		if len(candidates) == 1 {
			for t in candidates {
				result[var_info.symbol_id] = t
				break
			}
		} else {
			// Multiple candidates — widen (union or promotion)
			best := widen_candidates(candidates, reg)
			if best != TYPE_UNKNOWN {
				result[var_info.symbol_id] = best
			}
		}
	}

	return result
}

// Resolve a single constraint to candidate owner types
resolve_single_constraint :: proc(
	c: Constraint,
	method_table: ^Builtin_Method_Table,
	reg: ^Type_Registry,
	allocator: mem.Allocator,
) -> []Type_ID {
	result := make([dynamic]Type_ID, 0, 8, allocator)

	#partial switch cv in c {
	case Has_Method:
		if owners, ok := method_table.by_name[cv.method_name]; ok {
			for &owner in owners {
				// Filter by arg count compatibility (relaxed)
				if len(owner.signature.params) > 0 && len(cv.arg_types) > 0 {
					// If method has specific arg types, check first arg compatibility
					if owner.signature.params[0] != TYPE_ANY && len(cv.arg_types) > 0 {
						if cv.arg_types[0] != TYPE_UNKNOWN &&
						   !is_assignable(reg, cv.arg_types[0], owner.signature.params[0]) {
							continue // Arg type mismatch
						}
					}
				}
				// Only add concrete types (not TYPE_ANY placeholders for generic methods)
				if owner.owner_type != TYPE_ANY {
					append(&result, owner.owner_type)
				}
			}
		}

		// Also check user-defined classes
		for _, ct_id in reg.class_types {
			t := get_type(reg, ct_id)
			#partial switch cls in t.info {
			case Class_Type:
				if _, has := cls.attrs[cv.method_name]; has {
					// Class has this method — add instance type
					inst_id := make_instance_type(reg, ct_id)
					append(&result, inst_id)
				}
			}
		}

	case Has_Attr:
		// Check user-defined classes for the attribute
		for _, ct_id in reg.class_types {
			t := get_type(reg, ct_id)
			#partial switch cls in t.info {
			case Class_Type:
				if _, has := cls.attrs[cv.attr_name]; has {
					inst_id := make_instance_type(reg, ct_id)
					append(&result, inst_id)
				}
			}
		}

		// Check builtin types with known attributes
		// str has no non-method attributes typically, but check common ones
		// Modules have attributes — skip for now (params aren't usually modules)

	case Callable_With:
		// The symbol itself is callable — could be a function or class
		// For Phase I, this is hard to resolve without more context
		// Leave empty — won't constrain the type

	case Iterable_Of:
		// Known iterable types
		append(&result, TYPE_STR)
		append(&result, TYPE_BYTES)
		// list, dict, set, tuple are all iterable but their Type_IDs
		// vary by element type. For Phase I, we can't resolve this
		// without knowing the element type.

	case Subscriptable:
		// Known subscriptable types
		append(&result, TYPE_STR)   // str[int] → str
		append(&result, TYPE_BYTES) // bytes[int] → int
		// list, dict, tuple are subscriptable but Type_IDs vary

	case Type_Subtype:
		// Direct type constraint: var must be assignable to cv.type_id
		// The candidate is the type itself (or subtypes)
		append(&result, cv.type_id)
		// Also add subtypes: bool <: int <: float
		if cv.type_id == TYPE_FLOAT {
			append(&result, TYPE_INT)
			append(&result, TYPE_BOOL)
		} else if cv.type_id == TYPE_INT {
			append(&result, TYPE_BOOL)
		}

	case Supports_Op:
		// Which types support this operation?
		is_unary := cv.other_type == TYPE_UNKNOWN
		#partial switch cv.op {
		case .Add:
			if cv.other_type == TYPE_STR {
				// str + str only — int + str is TypeError
				append(&result, TYPE_STR)
			} else {
				append(&result, TYPE_INT)
				append(&result, TYPE_FLOAT)
				append(&result, TYPE_BOOL)
				append(&result, TYPE_COMPLEX)
				// str + str when other is unknown
				if cv.other_type == TYPE_UNKNOWN { append(&result, TYPE_STR) }
			}
		case .Sub, .Div, .Mod, .Pow, .Floor_Div:
			// Pure numeric (str doesn't support these)
			append(&result, TYPE_INT)
			append(&result, TYPE_FLOAT)
			append(&result, TYPE_BOOL)
			append(&result, TYPE_COMPLEX)
		case .Mul:
			append(&result, TYPE_INT)
			append(&result, TYPE_FLOAT)
			append(&result, TYPE_BOOL)
			append(&result, TYPE_COMPLEX)
			// str/bytes * int (repetition) — only if other is int-like
			if !is_unary && (cv.other_type == TYPE_INT || cv.other_type == TYPE_BOOL) {
				append(&result, TYPE_STR)
				append(&result, TYPE_BYTES)
			}
		case .Bit_And, .Bit_Or, .Bit_Xor:
			append(&result, TYPE_INT)
			append(&result, TYPE_BOOL)
		case .Eq, .Not_Eq:
			// Everything supports ==, no narrowing
		case .Lt, .Lt_E, .Gt, .Gt_E:
			append(&result, TYPE_INT)
			append(&result, TYPE_FLOAT)
			append(&result, TYPE_BOOL)
			append(&result, TYPE_STR)
			append(&result, TYPE_BYTES)
		}
	}

	return result[:]
}

// Widen multiple candidates into the best resolved type.
// Applies Python's numeric promotion hierarchy (bool <: int <: float <: complex),
// then falls back to priority-based selection for non-numeric types.
// Only builds union types when candidates are truly disjoint (e.g., str | int from callers).
widen_candidates :: proc(candidates: map[Type_ID]bool, reg: ^Type_Registry) -> Type_ID {
	has_bool    := TYPE_BOOL    in candidates
	has_int     := TYPE_INT     in candidates
	has_float   := TYPE_FLOAT   in candidates
	has_complex := TYPE_COMPLEX in candidates

	// Reduce numeric promotion chain to narrowest useful type
	// For backward inference, we want the NARROWEST (most specific) type that
	// satisfies all constraints — not the widest. If both int and float are
	// candidates, the actual constraint only requires int (since int <: float).
	reduced := make(map[Type_ID]bool, len(candidates), reg.allocator)
	for t in candidates {
		// Skip float if int is also present (int is more specific)
		if t == TYPE_FLOAT && has_int { continue }
		// Skip complex if int or float present
		if t == TYPE_COMPLEX && (has_int || has_float) { continue }
		// Skip bool if int is also present (int is more useful)
		if t == TYPE_BOOL && has_int { continue }
		reduced[t] = true
	}

	if len(reduced) == 1 {
		for t in reduced { return t }
	}

	if len(reduced) == 0 {
		// All were subsumed — this shouldn't happen, but fall back
		for t in candidates { return t }
		return TYPE_UNKNOWN
	}

	// For backward inference from body constraints, prefer the most common type.
	// Priority: int > str > float > bytes > bool > complex > instance types
	priority := [?]Type_ID{TYPE_INT, TYPE_STR, TYPE_FLOAT, TYPE_BYTES, TYPE_BOOL, TYPE_COMPLEX}
	for p in priority {
		if p in reduced { return p }
	}

	// Return first instance type
	for t in reduced { return t }
	return TYPE_UNKNOWN
}

// ==================== Caller→Param Type Collection ====================

// Caller_Param_Types maps callee scope → param_index → type observed at call site.
// Multiple callers with different types for the same param are merged.
Caller_Param_Types :: map[binder.Scope_ID]map[int]Type_ID

// Build sym_id → scope_id map for functions. Call once, reuse across rounds.
build_sym_to_scope :: proc(bind_result: ^binder.Bind_Result, allocator: mem.Allocator) -> map[binder.Symbol_ID]binder.Scope_ID {
	sym_to_scope := make(map[binder.Symbol_ID]binder.Scope_ID, 16, allocator)
	for &scope in bind_result.scopes {
		if scope.kind != .Function && scope.kind != .Lambda { continue }
		parent := binder.result_get_scope(bind_result, scope.parent_id)
		if parent == nil { continue }
		if func_sym, ok := parent.symbols[scope.name]; ok {
			sym_to_scope[func_sym] = scope.id
		}
	}
	return sym_to_scope
}

// Scan call sites to collect argument types for callee params.
// For each call f(arg1, arg2) where f is a known function:
//   - Look up f's scope_id
//   - Record arg types as evidence for f's param types
collect_caller_param_types :: proc(
	result: ^Check_Result,
	bind_result: ^binder.Bind_Result,
	flow_result: ^flow.Flow_Result,
	func_args_map: ^map[binder.Scope_ID]^parser.Arguments,
	sym_to_scope: ^map[binder.Symbol_ID]binder.Scope_ID,
	reg: ^Type_Registry,
	allocator: mem.Allocator,
) -> Caller_Param_Types {
	cpt := make(Caller_Param_Types, 8, allocator)

	// Walk all scopes' CFGs looking for call expressions
	for &cfg in flow_result.cfgs {
		for &block in cfg.blocks {
			if !block.is_reachable { continue }
			for stmt in block.stmts {
				collect_calls_in_stmt(stmt, result, bind_result, sym_to_scope, func_args_map, reg, &cpt, allocator)
			}
		}
	}

	return cpt
}

// Walk statements to find call expressions
collect_calls_in_stmt :: proc(
	stmt: parser.Stmt,
	result: ^Check_Result,
	bind_result: ^binder.Bind_Result,
	sym_to_scope: ^map[binder.Symbol_ID]binder.Scope_ID,
	func_args_map: ^map[binder.Scope_ID]^parser.Arguments,
	reg: ^Type_Registry,
	cpt: ^Caller_Param_Types,
	allocator: mem.Allocator,
) {
	visitor := core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			if expr == nil { return }
			ctx := cast(^Caller_Call_Ctx)raw_ctx
			call, is_call := expr.(^parser.Call_Expr)
			if !is_call { return }

			// Only handle direct name calls: f(args)
			name, is_name := call.func.(^parser.Name_Expr)
			if !is_name { return }

			func_sym, ref_ok := binder.get_ref(ctx.bind_result, rawptr(name))
			if !ref_ok { return }

			// Find the callee's scope
			callee_scope, has_scope := ctx.sym_to_scope[func_sym]
			if !has_scope { return }

			// Check if callee has unannotated params (via func_args_map)
			callee_args, has_args := ctx.func_args_map[callee_scope]
			if !has_args || callee_args == nil { return }

			// For each positional arg, record its type as evidence
			n_params := len(callee_args.posonlyargs) + len(callee_args.args)
			for arg, i in call.args {
				if i >= n_params { break }
				arg_ptr := expr_to_rawptr(arg)
				arg_type, has_type := ctx.result.expr_types[arg_ptr]
				if !has_type { continue }
				if arg_type == TYPE_UNKNOWN || arg_type == TYPE_ANY { continue }

				// Record: callee_scope, param_index i, observed type
				if callee_scope not_in ctx.cpt {
					ctx.cpt[callee_scope] = make(map[int]Type_ID, 4, ctx.allocator)
				}
				param_map := &ctx.cpt[callee_scope]
				if existing, ok := param_map[i]; ok {
					// Multiple callers — widen to union if different
					if existing != arg_type {
						types := [?]Type_ID{existing, arg_type}
						param_map[i] = make_union_type(ctx.reg, types[:])
					}
				} else {
					param_map[i] = arg_type
				}
			}
		},
		ctx = nil, // set below
	}

	ctx := Caller_Call_Ctx{
		result        = result,
		bind_result   = bind_result,
		sym_to_scope  = sym_to_scope,
		func_args_map = func_args_map,
		reg           = reg,
		cpt           = cpt,
		allocator     = allocator,
	}
	visitor.ctx = rawptr(&ctx)
	core.walk_stmt(&visitor, stmt)
}

Caller_Call_Ctx :: struct {
	result:        ^Check_Result,
	bind_result:   ^binder.Bind_Result,
	sym_to_scope:  ^map[binder.Symbol_ID]binder.Scope_ID,
	func_args_map: ^map[binder.Scope_ID]^parser.Arguments,
	reg:           ^Type_Registry,
	cpt:           ^Caller_Param_Types,
	allocator:     mem.Allocator,
}

// ==================== Enhanced Resolution with Caller Types ====================

// Resolve constraints with additional evidence from callers.
// caller_param_types: param_index → Type_ID from call sites.
// func_args: the AST Arguments for this function (for ordered param mapping).
resolve_constraints_with_callers :: proc(
	cs: ^Constraint_Set,
	method_table: ^Builtin_Method_Table,
	reg: ^Type_Registry,
	scope: ^binder.Scope,
	bind_result: ^binder.Bind_Result,
	caller_param_types: map[int]Type_ID,
	func_args: ^parser.Arguments,
	allocator: mem.Allocator,
) -> map[binder.Symbol_ID]Type_ID {
	result := make(map[binder.Symbol_ID]Type_ID, 8, allocator)

	// Build param_index → symbol_id map using AST argument order
	param_indices := make(map[binder.Symbol_ID]int, 8, allocator)
	if scope != nil && func_args != nil {
		// Map positional args by their AST order
		idx := 0
		for &arg in func_args.posonlyargs {
			if arg.arg == "self" || arg.arg == "cls" { idx += 1; continue }
			if sym_id, ok := scope.symbols[arg.arg]; ok {
				param_indices[sym_id] = idx
			}
			idx += 1
		}
		for &arg in func_args.args {
			if arg.arg == "self" || arg.arg == "cls" { idx += 1; continue }
			if sym_id, ok := scope.symbols[arg.arg]; ok {
				param_indices[sym_id] = idx
			}
			idx += 1
		}
	}

	for &var_info in cs.vars {
		if var_info.forward_type != TYPE_UNKNOWN { continue }

		constraint_indices, ok := cs.var_constraints[var_info.id]

		// Body-derived candidates
		first := true
		candidates := make(map[Type_ID]bool, 16, allocator)

		if ok && len(constraint_indices) > 0 {
			for ci in constraint_indices {
				c := cs.constraints[ci]
				matches := resolve_single_constraint(c, method_table, reg, allocator)
				if len(matches) == 0 { continue }

				if first {
					for t in matches { candidates[t] = true }
					first = false
				} else {
					to_remove := make([dynamic]Type_ID, 0, 8, allocator)
					for t in candidates {
						found := false
						for m in matches {
							if m == t { found = true; break }
						}
						if !found { append(&to_remove, t) }
					}
					for t in to_remove { delete_key(&candidates, t) }
				}
			}
		}

		// Caller-derived evidence
		caller_type := TYPE_UNKNOWN
		if pidx, has_pidx := param_indices[var_info.symbol_id]; has_pidx {
			if ct, has_ct := caller_param_types[pidx]; has_ct {
				caller_type = ct
			}
		}

		// Merge body candidates with caller evidence
		if caller_type != TYPE_UNKNOWN {
			if first {
				// No body constraints — use caller type directly
				result[var_info.symbol_id] = caller_type
				continue
			} else if caller_type in candidates {
				// Caller type agrees with body — use it (most specific)
				result[var_info.symbol_id] = caller_type
				continue
			} else if len(candidates) == 0 {
				// Body intersection was empty — use caller type
				result[var_info.symbol_id] = caller_type
				continue
			}
			// Caller type not in body candidates — body takes precedence
			// (caller may be wrong, body usage is authoritative)
		}

		if len(candidates) == 0 { continue }

		if len(candidates) == 1 {
			for t in candidates {
				result[var_info.symbol_id] = t
				break
			}
		} else {
			// Multiple candidates — widen to union or pick promoted type
			best := widen_candidates(candidates, reg)
			if best != TYPE_UNKNOWN {
				result[var_info.symbol_id] = best
			}
		}
	}

	return result
}

// ==================== Integration Helpers ====================

// Find parameters that forward inference left as TYPE_UNKNOWN
find_unknown_params :: proc(
	cfg: ^flow.CFG,
	scope: ^binder.Scope,
	envs: []Type_Env,
	bind_result: ^binder.Bind_Result,
	reg: ^Type_Registry,
) -> [dynamic]binder.Symbol_ID {
	result := make([dynamic]binder.Symbol_ID, 0, 8, reg.allocator)
	if scope == nil { return result }
	if scope.kind != .Function && scope.kind != .Lambda { return result }

	for name, sym_id in scope.symbols {
		sym := binder.result_get_symbol(bind_result, sym_id)
		if sym == nil { continue }
		if .Is_Param not_in sym.flags { continue }
		if name == "self" || name == "cls" { continue }

		// Check if param type is UNKNOWN in the entry block env
		entry_idx := int(cfg.entry) - 1
		if entry_idx < 0 || entry_idx >= len(envs) { continue }

		entry_type := TYPE_UNKNOWN
		if t, ok := envs[entry_idx].types[sym_id]; ok {
			entry_type = t
		}
		if entry_type == TYPE_UNKNOWN {
			append(&result, sym_id)
		}
	}

	return result
}
