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

		if len(candidates) == 0 {
			// No concrete type matches — try protocol synthesis as fallback
			proto := synthesize_protocol(cs, var_info.id, reg, allocator)
			if proto != TYPE_UNKNOWN {
				result[var_info.symbol_id] = proto
			}
			continue
		}

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

		// Container type inference from method names
		// List methods: append, extend, insert, pop, sort, reverse, copy, remove
		switch cv.method_name {
		case "append", "remove":
			// x.append(val) → x is list[typeof(val)]
			elem := TYPE_ANY
			if len(cv.arg_types) > 0 && cv.arg_types[0] != TYPE_UNKNOWN {
				elem = cv.arg_types[0]
			}
			append(&result, make_list_type(reg, elem))
		case "insert":
			// x.insert(i, val) → x is list[typeof(val)]
			elem := TYPE_ANY
			if len(cv.arg_types) > 1 && cv.arg_types[1] != TYPE_UNKNOWN {
				elem = cv.arg_types[1]
			}
			append(&result, make_list_type(reg, elem))
		case "pop":
			// x.pop() → x is list[typeof(return)]
			elem := TYPE_ANY
			if cv.return_type != TYPE_UNKNOWN && cv.return_type != TYPE_ANY {
				elem = cv.return_type
			}
			append(&result, make_list_type(reg, elem))
		case "sort", "reverse":
			// List-exclusive methods (dict/set don't have these)
			append(&result, make_list_type(reg, TYPE_ANY))
		case "extend":
			// List-exclusive (set uses update, dict uses update)
			append(&result, make_list_type(reg, TYPE_ANY))
		case "copy":
			// Shared: list, dict, and set all have copy()
			append(&result, make_list_type(reg, TYPE_ANY))
			append(&result, make_dict_type(reg, TYPE_ANY, TYPE_ANY))
			append(&result, make_set_type(reg, TYPE_ANY))
		case "clear":
			// Shared: list, dict, and set all have clear()
			append(&result, make_list_type(reg, TYPE_ANY))
			append(&result, make_dict_type(reg, TYPE_ANY, TYPE_ANY))
			append(&result, make_set_type(reg, TYPE_ANY))
		case "keys", "values", "items":
			// Dict methods
			append(&result, make_dict_type(reg, TYPE_ANY, TYPE_ANY))
		case "get":
			// x.get(key) → x is dict[typeof(key), Any]
			key := TYPE_ANY
			if len(cv.arg_types) > 0 && cv.arg_types[0] != TYPE_UNKNOWN {
				key = cv.arg_types[0]
			}
			append(&result, make_dict_type(reg, key, TYPE_ANY))
		case "setdefault":
			// x.setdefault(key, val) → x is dict[typeof(key), typeof(val)]
			key, val := TYPE_ANY, TYPE_ANY
			if len(cv.arg_types) > 0 && cv.arg_types[0] != TYPE_UNKNOWN { key = cv.arg_types[0] }
			if len(cv.arg_types) > 1 && cv.arg_types[1] != TYPE_UNKNOWN { val = cv.arg_types[1] }
			append(&result, make_dict_type(reg, key, val))
		case "add", "discard":
			// x.add(val) → x is set[typeof(val)]
			elem := TYPE_ANY
			if len(cv.arg_types) > 0 && cv.arg_types[0] != TYPE_UNKNOWN {
				elem = cv.arg_types[0]
			}
			append(&result, make_set_type(reg, elem))
		case "union", "intersection", "difference":
			// Set operations
			append(&result, make_set_type(reg, TYPE_ANY))
		case "issubset", "issuperset":
			append(&result, make_set_type(reg, TYPE_ANY))
		case "update":
			// Shared: dict.update(other_dict) and set.update(other_set)
			append(&result, make_dict_type(reg, TYPE_ANY, TYPE_ANY))
			append(&result, make_set_type(reg, TYPE_ANY))
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
		// x(args) → x is Callable with matching signature
		// Construct a Callable_Type from observed arg/return types
		params := make([]Param_Type, len(cv.arg_types), allocator)
		for a, i in cv.arg_types {
			params[i] = Param_Type{
				name    = "",
				type_id = a if a != TYPE_UNKNOWN else TYPE_ANY,
			}
		}
		ret := cv.return_type if cv.return_type != TYPE_UNKNOWN else TYPE_ANY
		callable_id := make_callable_type(reg, params, ret)
		append(&result, callable_id)

	case Iterable_Of:
		// Known iterable types
		append(&result, TYPE_STR)
		append(&result, TYPE_BYTES)
		// Container types — construct with element type evidence
		if cv.element_type != TYPE_UNKNOWN && cv.element_type != TYPE_ANY {
			append(&result, make_list_type(reg, cv.element_type))
			append(&result, make_set_type(reg, cv.element_type))
		} else {
			append(&result, make_list_type(reg, TYPE_ANY))
		}

	case Subscriptable:
		// Known subscriptable types
		append(&result, TYPE_STR)   // str[int] → str
		append(&result, TYPE_BYTES) // bytes[int] → int
		// Container types — construct with key/value evidence
		val := cv.value_type if cv.value_type != TYPE_UNKNOWN else TYPE_ANY
		if cv.key_type == TYPE_INT || cv.key_type == TYPE_UNKNOWN {
			// x[int] → could be list
			append(&result, make_list_type(reg, val))
		}
		if cv.key_type == TYPE_STR {
			// x[str] → dict[str, V]
			append(&result, make_dict_type(reg, TYPE_STR, val))
		}
		if cv.key_type != TYPE_INT && cv.key_type != TYPE_STR && cv.key_type != TYPE_UNKNOWN {
			// x[other_key_type] → dict[K, V]
			append(&result, make_dict_type(reg, cv.key_type, val))
		}

	case Dict_Key_Set:
		// x["key"] = val → x is dict-like (TypedDict synthesized in fallback)
		// For intersection, produce dict[str, val_type] as candidate
		val := cv.value_type if cv.value_type != TYPE_UNKNOWN else TYPE_ANY
		append(&result, make_dict_type(reg, TYPE_STR, val))

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

	// Multiple non-promotion candidates remain — check if all are primitives
	// If so, pick narrowest by priority (backward inference heuristic).
	// If mixed primitive+non-primitive, build union per spec "conflict → union".
	all_primitive := true
	for t in reduced {
		if t != TYPE_INT && t != TYPE_FLOAT && t != TYPE_BOOL && t != TYPE_COMPLEX &&
		   t != TYPE_STR && t != TYPE_BYTES {
			all_primitive = false
			break
		}
	}

	if all_primitive {
		// All primitives — pick narrowest (backward inference heuristic)
		priority := [?]Type_ID{TYPE_INT, TYPE_STR, TYPE_FLOAT, TYPE_BYTES, TYPE_BOOL, TYPE_COMPLEX}
		for p in priority {
			if p in reduced { return p }
		}
	}

	// Mixed or non-primitive candidates — build union (spec: conflict → union)
	types := make([dynamic]Type_ID, 0, len(reduced), reg.allocator)
	for t in reduced { append(&types, t) }
	return make_union_type(reg, types[:])
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

		if scope.kind == .Function {
			if func_sym, ok := parent.symbols[scope.name]; ok {
				sym_to_scope[func_sym] = scope.id
			}
		} else if scope.kind == .Lambda {
			// Lambda scopes have name "<lambda>" — not in parent.symbols.
			// Find the variable assigned the lambda by matching def location.
			for _, sym_id in parent.symbols {
				sym := binder.result_get_symbol(bind_result, sym_id)
				if sym == nil { continue }
				// Match: variable defined at same line as lambda scope
				if sym.def_loc.line == scope.loc.line {
					sym_to_scope[sym_id] = scope.id
					break
				}
			}
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

			callee_scope: binder.Scope_ID
			callee_args: ^parser.Arguments
			self_offset := 0  // 0 for direct calls, 1 for method calls (implicit self)

			// Try direct name call: f(args)
			if name, is_name := call.func.(^parser.Name_Expr); is_name {
				func_sym, ref_ok := binder.get_ref(ctx.bind_result, rawptr(name))
				if !ref_ok { return }
				scope, has_scope := ctx.sym_to_scope[func_sym]
				if !has_scope { return }
				args, has_args := ctx.func_args_map[scope]
				if !has_args || args == nil { return }
				callee_scope = scope
				callee_args = args
			} else if attr, is_attr := call.func.(^parser.Attribute_Expr); is_attr {
				// Method call: obj.method(args) — resolve obj type → class → method scope
				obj_type, has_obj := ctx.result.expr_types[expr_to_rawptr(attr.value)]
				if !has_obj { return }

				// Unwrap Instance_Type → Class_Type
				class_type_id := TYPE_UNKNOWN
				t := get_type(ctx.reg, obj_type)
				#partial switch info in t.info {
				case Instance_Type:
					class_type_id = info.class_type
				case Class_Type:
					class_type_id = obj_type
				}
				if class_type_id == TYPE_UNKNOWN { return }

				// Find method in class scope
				ct := get_type(ctx.reg, class_type_id)
				#partial switch cls in ct.info {
				case Class_Type:
					if cls.scope_id == binder.INVALID_SCOPE { return }
					class_scope := binder.result_get_scope(ctx.bind_result, cls.scope_id)
					if class_scope == nil { return }
					method_sym, has_method := class_scope.symbols[attr.attr]
					if !has_method { return }
					method_scope, has_scope := ctx.sym_to_scope[method_sym]
					if !has_scope { return }
					args, has_args := ctx.func_args_map[method_scope]
					if !has_args || args == nil { return }
					callee_scope = method_scope
					callee_args = args
					self_offset = 1  // skip self param
				}
				if callee_scope == binder.INVALID_SCOPE { return }
			} else {
				return
			}

			// For each positional arg, record its type as evidence
			// self_offset shifts the param index for method calls (implicit self)
			n_posonly := len(callee_args.posonlyargs)
			n_params := n_posonly + len(callee_args.args)
			for arg, i in call.args {
				param_idx := i + self_offset
				if param_idx >= n_params { break }
				arg_ptr := expr_to_rawptr(arg)
				arg_type, has_type := ctx.result.expr_types[arg_ptr]
				if !has_type { continue }
				if arg_type == TYPE_UNKNOWN || arg_type == TYPE_ANY { continue }

				record_caller_evidence(ctx.cpt, callee_scope, param_idx, arg_type, ctx.reg, ctx.allocator)
			}

			// For each keyword arg, match by name to find param index
			for &kw in call.keywords {
				if kw.arg == "" { continue } // **kwargs unpacking, skip
				kw_type, has_kw := ctx.result.expr_types[expr_to_rawptr(kw.value)]
				if !has_kw { continue }
				if kw_type == TYPE_UNKNOWN || kw_type == TYPE_ANY { continue }

				// Find param index by name in callee's args
				found_idx := -1
				idx := 0
				for &param in callee_args.posonlyargs {
					if param.arg == kw.arg { found_idx = idx; break }
					idx += 1
				}
				if found_idx == -1 {
					for &param in callee_args.args {
						if param.arg == kw.arg { found_idx = idx; break }
						idx += 1
					}
				}
				if found_idx == -1 { continue }

				record_caller_evidence(ctx.cpt, callee_scope, found_idx, kw_type, ctx.reg, ctx.allocator)
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

// Record caller evidence for a callee param at a given index
record_caller_evidence :: proc(
	cpt: ^Caller_Param_Types,
	callee_scope: binder.Scope_ID,
	param_idx: int,
	arg_type: Type_ID,
	reg: ^Type_Registry,
	allocator: mem.Allocator,
) {
	if callee_scope not_in cpt {
		cpt[callee_scope] = make(map[int]Type_ID, 4, allocator)
	}
	param_map := &cpt[callee_scope]
	if existing, ok := param_map[param_idx]; ok {
		if existing != arg_type {
			types := [?]Type_ID{existing, arg_type}
			param_map[param_idx] = make_union_type(reg, types[:])
		}
	} else {
		param_map[param_idx] = arg_type
	}
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

// ==================== Protocol Inference (§3.6) ====================

// Synthesize a structural type from accumulated constraints on a variable.
// Tries TypedDict first (if Dict_Key_Set constraints present), then Protocol.
// Fallback when no concrete type matches all constraints.
synthesize_structural_type :: proc(
	cs: ^Constraint_Set,
	var_id: Constraint_Var,
	reg: ^Type_Registry,
	allocator: mem.Allocator,
) -> Type_ID {
	constraint_indices, ok := cs.var_constraints[var_id]
	if !ok || len(constraint_indices) == 0 { return TYPE_UNKNOWN }

	methods    := make(map[string]Type_ID, 4, allocator)
	attrs      := make(map[string]Type_ID, 4, allocator)
	dict_keys  := make(map[string]Type_ID, 4, allocator)

	for ci in constraint_indices {
		c := cs.constraints[ci]
		#partial switch cv in c {
		case Has_Method:
			params := make([]Param_Type, len(cv.arg_types), allocator)
			for a, i in cv.arg_types {
				params[i] = Param_Type{
					name    = "",
					type_id = a if a != TYPE_UNKNOWN else TYPE_ANY,
				}
			}
			ret := cv.return_type if cv.return_type != TYPE_UNKNOWN else TYPE_ANY
			methods[cv.method_name] = make_callable_type(reg, params, ret)
		case Has_Attr:
			attr_type := cv.attr_type if cv.attr_type != TYPE_UNKNOWN else TYPE_ANY
			attrs[cv.attr_name] = attr_type
		case Dict_Key_Set:
			val_type := cv.value_type if cv.value_type != TYPE_UNKNOWN else TYPE_ANY
			dict_keys[cv.key] = val_type
		}
	}

	// §3.5: If Dict_Key_Set constraints present → synthesize TypedDict
	if len(dict_keys) > 0 {
		return make_typeddict_type(reg, "", dict_keys, true)
	}

	// §3.6: If Has_Method/Has_Attr present → synthesize Protocol
	if len(methods) > 0 || len(attrs) > 0 {
		return register_type(reg, Protocol_Type{
			name    = "",
			methods = methods,
			attrs   = attrs,
		})
	}

	return TYPE_UNKNOWN
}

// Keep old name as alias for backward compatibility
synthesize_protocol :: proc(
	cs: ^Constraint_Set,
	var_id: Constraint_Var,
	reg: ^Type_Registry,
	allocator: mem.Allocator,
) -> Type_ID {
	return synthesize_structural_type(cs, var_id, reg, allocator)
}

// ==================== Enhanced Resolution with Caller Types ====================

// Conflict between body constraints and caller evidence
Constraint_Conflict :: struct {
	symbol_id:    binder.Symbol_ID,
	param_name:   string,
	caller_type:  Type_ID,
	body_types:   [dynamic]Type_ID,
	loc:          parser.Src_Loc,
}

// Resolve constraints with additional evidence from callers.
// caller_param_types: param_index → Type_ID from call sites.
// func_args: the AST Arguments for this function (for ordered param mapping).
// Returns resolved types + any conflicts detected.
resolve_constraints_with_callers :: proc(
	cs: ^Constraint_Set,
	method_table: ^Builtin_Method_Table,
	reg: ^Type_Registry,
	scope: ^binder.Scope,
	bind_result: ^binder.Bind_Result,
	caller_param_types: map[int]Type_ID,
	func_args: ^parser.Arguments,
	allocator: mem.Allocator,
	conflicts: ^[dynamic]Constraint_Conflict = nil,
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
			// Caller type not in body candidates — conflict detected
			// Body usage is authoritative, but record the conflict
			if conflicts != nil {
				body_types := make([dynamic]Type_ID, 0, len(candidates), allocator)
				for t in candidates { append(&body_types, t) }
				sym := binder.result_get_symbol(bind_result, var_info.symbol_id)
				param_name := sym.name if sym != nil else ""
				// Find loc from first constraint
				loc: parser.Src_Loc
				if ok && len(constraint_indices) > 0 {
					#partial switch cv in cs.constraints[constraint_indices[0]] {
					case Has_Method:    loc = cv.loc
					case Has_Attr:      loc = cv.loc
					case Callable_With: loc = cv.loc
					case Supports_Op:   loc = cv.loc
					}
				}
				append(conflicts, Constraint_Conflict{
					symbol_id   = var_info.symbol_id,
					param_name  = param_name,
					caller_type = caller_type,
					body_types  = body_types,
					loc         = loc,
				})
			}
		}

		if len(candidates) == 0 {
			// No concrete type — try protocol synthesis
			proto := synthesize_protocol(cs, var_info.id, reg, allocator)
			if proto != TYPE_UNKNOWN {
				result[var_info.symbol_id] = proto
			}
			continue
		}

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
