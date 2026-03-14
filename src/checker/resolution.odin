package checker

import "core:mem"
import binder "mimir:binder"
import flow   "mimir:flow"

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
			// Multiple candidates — pick the most specific
			best := pick_most_specific(candidates, reg)
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
			append(&result, TYPE_INT)
			append(&result, TYPE_FLOAT)
			append(&result, TYPE_BOOL)
			append(&result, TYPE_COMPLEX)
			// str + str (concatenation)
			if cv.other_type == TYPE_STR { append(&result, TYPE_STR) }
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

// When multiple types match all constraints, pick the most specific one.
// Priority: int > float > str > bytes > bool. Int is the most common Python type
// and the most likely backward inference target for arithmetic operations.
pick_most_specific :: proc(candidates: map[Type_ID]bool, reg: ^Type_Registry) -> Type_ID {
	priority := [?]Type_ID{TYPE_INT, TYPE_FLOAT, TYPE_STR, TYPE_BYTES, TYPE_BOOL}
	for p in priority {
		if p in candidates { return p }
	}

	// Return first instance type if any
	for t in candidates {
		return t
	}

	return TYPE_UNKNOWN
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
