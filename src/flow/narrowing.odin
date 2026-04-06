package flow

import parser "mimir:parser"
import binder "mimir:binder"
import "core:mem"

// ==================== Types ====================

Guard_Kind :: enum u8 {
	Is_Instance,
	Is_Not_Instance,
	Is_None,
	Is_Not_None,
	Is_Truthy,
	Is_Falsy,
	Type_Is,
	Type_Is_Not,
	Type_Guard,       // TypeGuard function call — resolved_type has target
	Type_Is_Guard,    // TypeIs (PEP 742) — narrows in BOTH branches (subtract in false)
	Is_Callable,      // callable(x) — narrows to callable types only
	Is_Not_Callable,  // not callable(x) — removes callable types
}

Guard :: struct {
	kind:          Guard_Kind,
	symbol_id:     binder.Symbol_ID,
	attr_name:     string,        // Non-empty for attribute narrowing (e.g., "attr" for obj.attr)
	type_expr:     parser.Expr,
	branch_block:  Block_ID,
	true_block:    Block_ID,
	false_block:   Block_ID,
	loc:           parser.Src_Loc,
	resolved_type: u32,  // Pre-resolved Type_ID for TypeGuard (0 = use type_expr instead)
}

// ==================== Extraction ====================

extract_guards :: proc(cfgs: []CFG, bind_result: ^binder.Bind_Result, allocator: mem.Allocator) -> [dynamic]Guard {
	guards := make([dynamic]Guard, 0, 16, allocator)

	for &cfg in cfgs {
		for &block in cfg.blocks {
			if !block.is_reachable { continue }
			if len(block.stmts) == 0 { continue }

			last_stmt := block.stmts[len(block.stmts) - 1]

			#partial switch s in last_stmt {
			case ^parser.If_Stmt:
				true_block := find_succ_by_edge_kind(&block, .True_Branch)
				false_block := find_succ_by_edge_kind(&block, .False_Branch)
				if true_block != INVALID_BLOCK && false_block != INVALID_BLOCK {
					analyze_condition(s.test, bind_result, cfg.scope_id, block.id, true_block, false_block, s.loc, &guards, allocator)
				}

			case ^parser.While_Stmt:
				true_block := find_succ_by_edge_kind(&block, .True_Branch)
				false_block := find_succ_by_edge_kind(&block, .False_Branch)
				if true_block != INVALID_BLOCK && false_block != INVALID_BLOCK {
					analyze_condition(s.test, bind_result, cfg.scope_id, block.id, true_block, false_block, s.loc, &guards, allocator)
				}
			}
		}
	}

	return guards
}

find_succ_by_edge_kind :: proc(block: ^Block, kind: Edge_Kind) -> Block_ID {
	for succ_id, i in block.succs {
		if block.edge_kinds[i] == kind {
			return succ_id
		}
	}
	return INVALID_BLOCK
}

// ==================== Condition Analysis ====================

analyze_condition :: proc(
	expr: parser.Expr,
	bind_result: ^binder.Bind_Result,
	scope_id: binder.Scope_ID,
	branch_block: Block_ID,
	true_block: Block_ID,
	false_block: Block_ID,
	loc: parser.Src_Loc,
	guards: ^[dynamic]Guard,
	allocator: mem.Allocator,
) {
	if expr == nil { return }

	#partial switch e in expr {
	case ^parser.Call_Expr:
		// isinstance(x, T) or isinstance(obj.attr, T)
		if is_isinstance_call(e, bind_result) {
			if len(e.args) >= 2 {
				// Try attribute pattern first: isinstance(obj.attr, T)
				if attr, is_attr := e.args[0].(^parser.Attribute_Expr); is_attr {
					base_sym := expr_to_symbol(attr.value, bind_result, scope_id)
					if base_sym != binder.INVALID_SYMBOL {
						append(guards, Guard{
							kind         = .Is_Instance,
							symbol_id    = base_sym,
							attr_name    = attr.attr,
							type_expr    = e.args[1],
							branch_block = branch_block,
							true_block   = true_block,
							false_block  = false_block,
							loc          = loc,
						})
					}
				}
				sym_id := expr_to_symbol(e.args[0], bind_result, scope_id)
				if sym_id != binder.INVALID_SYMBOL {
					append(guards, Guard{
						kind         = .Is_Instance,
						symbol_id    = sym_id,
						type_expr    = e.args[1],
						branch_block = branch_block,
						true_block   = true_block,
						false_block  = false_block,
						loc          = loc,
					})
				}
			}
		} else if is_callable_call(e) && len(e.args) >= 1 {
			// callable(x) — narrows to callable types in true branch
			sym_id := expr_to_symbol(e.args[0], bind_result, scope_id)
			if sym_id != binder.INVALID_SYMBOL {
				append(guards, Guard{
					kind         = .Is_Callable,
					symbol_id    = sym_id,
					branch_block = branch_block,
					true_block   = true_block,
					false_block  = false_block,
					loc          = loc,
				})
			}
		} else if len(e.args) >= 1 {
			// Potential TypeGuard call: func(arg) where func returns TypeGuard[T]
			// Create a Type_Guard guard — checker verifies if func is actually a TypeGuard
			if name, name_ok := e.func.(^parser.Name_Expr); name_ok {
				func_sym, ref_ok := binder.get_ref(bind_result, rawptr(name))
				if ref_ok {
					arg_sym := expr_to_symbol(e.args[0], bind_result, scope_id)
					if arg_sym != binder.INVALID_SYMBOL {
						append(guards, Guard{
							kind          = .Type_Guard,
							symbol_id     = arg_sym,
							type_expr     = parser.Expr(name), // store func name for checker lookup
							branch_block  = branch_block,
							true_block    = true_block,
							false_block   = false_block,
							loc           = loc,
							resolved_type = u32(func_sym), // store func sym_id for TypeGuard target lookup
						})
					}
				}
			}
		}

	case ^parser.Compare_Expr:
		if len(e.ops) == 1 && len(e.comparators) == 1 {
			// x is None / x is not None / obj.attr is None / obj.attr is not None
			if is_none_compare(e) {
				// Try attribute pattern: obj.attr is None
				if attr, is_attr := e.left.(^parser.Attribute_Expr); is_attr {
					base_sym := expr_to_symbol(attr.value, bind_result, scope_id)
					if base_sym != binder.INVALID_SYMBOL {
						tb := e.ops[0] == .Is ? true_block : false_block
						fb := e.ops[0] == .Is ? false_block : true_block
						append(guards, Guard{
							kind         = .Is_None,
							symbol_id    = base_sym,
							attr_name    = attr.attr,
							branch_block = branch_block,
							true_block   = tb,
							false_block  = fb,
							loc          = loc,
						})
					}
				}
				sym_id := expr_to_symbol(e.left, bind_result, scope_id)
				if sym_id != binder.INVALID_SYMBOL {
					// For "is not", use Is_None with swapped blocks (consistent with unary inversion)
					tb := e.ops[0] == .Is ? true_block : false_block
					fb := e.ops[0] == .Is ? false_block : true_block
					append(guards, Guard{
						kind         = .Is_None,
						symbol_id    = sym_id,
						branch_block = branch_block,
						true_block   = tb,
						false_block  = fb,
						loc          = loc,
					})
				}
			}
			// None is x / None is not x (reversed) — also handle None is obj.attr
			if is_none_compare_reversed(e) {
				if attr, is_attr := e.comparators[0].(^parser.Attribute_Expr); is_attr {
					base_sym := expr_to_symbol(attr.value, bind_result, scope_id)
					if base_sym != binder.INVALID_SYMBOL {
						tb := e.ops[0] == .Is ? true_block : false_block
						fb := e.ops[0] == .Is ? false_block : true_block
						append(guards, Guard{
							kind         = .Is_None,
							symbol_id    = base_sym,
							attr_name    = attr.attr,
							branch_block = branch_block,
							true_block   = tb,
							false_block  = fb,
							loc          = loc,
						})
					}
				}
				sym_id := expr_to_symbol(e.comparators[0], bind_result, scope_id)
				if sym_id != binder.INVALID_SYMBOL {
					tb := e.ops[0] == .Is ? true_block : false_block
					fb := e.ops[0] == .Is ? false_block : true_block
					append(guards, Guard{
						kind         = .Is_None,
						symbol_id    = sym_id,
						branch_block = branch_block,
						true_block   = tb,
						false_block  = fb,
						loc          = loc,
					})
				}
			}
			// type(x) is T / type(x) is not T
			if is_type_compare(e, bind_result) {
				call := e.left.(^parser.Call_Expr)
				if call != nil && len(call.args) >= 1 {
					sym_id := expr_to_symbol(call.args[0], bind_result, scope_id)
					if sym_id != binder.INVALID_SYMBOL {
						// For "is not", use Type_Is with swapped blocks
						tb := e.ops[0] == .Is ? true_block : false_block
						fb := e.ops[0] == .Is ? false_block : true_block
						append(guards, Guard{
							kind         = .Type_Is,
							symbol_id    = sym_id,
							type_expr    = e.comparators[0],
							branch_block = branch_block,
							true_block   = tb,
							false_block  = fb,
							loc          = loc,
						})
					}
				}
			}
		}

	case ^parser.Name_Expr:
		// if x: (truthiness)
		sym_id := expr_to_symbol(expr, bind_result, scope_id)
		if sym_id != binder.INVALID_SYMBOL {
			append(guards, Guard{
				kind         = .Is_Truthy,
				symbol_id    = sym_id,
				branch_block = branch_block,
				true_block   = true_block,
				false_block  = false_block,
				loc          = loc,
			})
		}

	case ^parser.Named_Expr:
		// if (x := value): (walrus + truthiness)
		sym_id := expr_to_symbol(e.target, bind_result, scope_id)
		if sym_id != binder.INVALID_SYMBOL {
			append(guards, Guard{
				kind         = .Is_Truthy,
				symbol_id    = sym_id,
				branch_block = branch_block,
				true_block   = true_block,
				false_block  = false_block,
				loc          = loc,
			})
		}

	case ^parser.Attribute_Expr:
		// if obj.attr: (attribute truthiness)
		base_sym := expr_to_symbol(e.value, bind_result, scope_id)
		if base_sym != binder.INVALID_SYMBOL {
			append(guards, Guard{
				kind         = .Is_Truthy,
				symbol_id    = base_sym,
				attr_name    = e.attr,
				branch_block = branch_block,
				true_block   = true_block,
				false_block  = false_block,
				loc          = loc,
			})
		}

	case ^parser.Unary_Op_Expr:
		// if not x: → invert
		if e.op == .Not {
			// Recursively analyze and invert
			temp_guards := make([dynamic]Guard, 0, 4, allocator)
			analyze_condition(e.operand, bind_result, scope_id, branch_block, true_block, false_block, loc, &temp_guards, allocator)
			for &g in temp_guards {
				g.kind = invert_guard_kind(g.kind)
				// Swap true/false blocks for inverted guards
				g.true_block, g.false_block = g.false_block, g.true_block
				append(guards, g)
			}
		}

	case ^parser.Bool_Op_Expr:
		if e.op == .And {
			// `x and isinstance(x, T)` — all sub-conditions produce guards for same branches
			for val in e.values {
				analyze_condition(val, bind_result, scope_id, branch_block, true_block, false_block, loc, guards, allocator)
			}
		} else if e.op == .Or {
			// `a or b` false branch: both a AND b are false → subtract each type.
			// Use normal blocks (not swapped) so false_block gets negative guards
			// (subtraction). True branch is imprecise (narrows to last type instead
			// of union) but correct subtraction in false branch is more important.
			for val in e.values {
				analyze_condition(val, bind_result, scope_id, branch_block, true_block, false_block, loc, guards, allocator)
			}
		}
	}
}

// ==================== Pattern Helpers ====================

is_isinstance_call :: proc(call: ^parser.Call_Expr, bind_result: ^binder.Bind_Result) -> bool {
	#partial switch f in call.func {
	case ^parser.Name_Expr:
		return f.id == "isinstance"
	}
	return false
}

is_callable_call :: proc(call: ^parser.Call_Expr) -> bool {
	#partial switch f in call.func {
	case ^parser.Name_Expr:
		return f.id == "callable"
	}
	return false
}

is_none_compare :: proc(cmp: ^parser.Compare_Expr) -> bool {
	if len(cmp.ops) != 1 { return false }
	op := cmp.ops[0]
	if op != .Is && op != .Is_Not { return false }

	// Right side is None constant
	#partial switch c in cmp.comparators[0] {
	case ^parser.Constant_Expr:
		_, is_none := c.value.(parser.Const_None)
		return is_none
	}
	return false
}

is_none_compare_reversed :: proc(cmp: ^parser.Compare_Expr) -> bool {
	if len(cmp.ops) != 1 { return false }
	op := cmp.ops[0]
	if op != .Is && op != .Is_Not { return false }

	// Left side is None constant
	#partial switch c in cmp.left {
	case ^parser.Constant_Expr:
		_, is_none := c.value.(parser.Const_None)
		return is_none
	}
	return false
}

is_type_compare :: proc(cmp: ^parser.Compare_Expr, bind_result: ^binder.Bind_Result) -> bool {
	if len(cmp.ops) != 1 { return false }
	op := cmp.ops[0]
	if op != .Is && op != .Is_Not { return false }

	// Left side is type(x) call
	#partial switch call in cmp.left {
	case ^parser.Call_Expr:
		#partial switch f in call.func {
		case ^parser.Name_Expr:
			return f.id == "type" && len(call.args) == 1
		}
	}
	return false
}

expr_to_symbol :: proc(expr: parser.Expr, bind_result: ^binder.Bind_Result, scope_id: binder.Scope_ID = binder.Scope_ID(0)) -> binder.Symbol_ID {
	if expr == nil { return binder.INVALID_SYMBOL }
	#partial switch e in expr {
	case ^parser.Name_Expr:
		sym_id, ok := binder.get_ref(bind_result, rawptr(e))
		if ok {
			return sym_id
		}
		// Fallback: scope-aware name search — prefer symbols in current/ancestor scopes
		if scope_id != binder.Scope_ID(0) {
			check_scope := scope_id
			for check_scope != binder.Scope_ID(0) {
				for &sym in bind_result.symbols {
					if sym.name == e.id && sym.scope_id == check_scope {
						return sym.id
					}
				}
				scope := binder.result_get_scope(bind_result, check_scope)
				if scope == nil { break }
				check_scope = scope.parent_id
			}
		} else {
			// No scope context — original behavior (first match)
			for &sym in bind_result.symbols {
				if sym.name == e.id {
					return sym.id
				}
			}
		}
	case ^parser.Named_Expr:
		// Walrus operator (x := value) — extract target symbol
		return expr_to_symbol(e.target, bind_result, scope_id)
	}
	return binder.INVALID_SYMBOL
}

// ==================== Guard Inversion ====================

invert_guard_kind :: proc(kind: Guard_Kind) -> Guard_Kind {
	switch kind {
	case .Is_Instance:     return .Is_Not_Instance
	case .Is_Not_Instance: return .Is_Instance
	case .Is_None:         return .Is_Not_None
	case .Is_Not_None:     return .Is_None
	case .Is_Truthy:       return .Is_Falsy
	case .Is_Falsy:        return .Is_Truthy
	case .Type_Is:         return .Type_Is_Not
	case .Type_Is_Not:     return .Type_Is
	case .Type_Guard:      return .Type_Guard  // TypeGuard inversion: no narrowing in false branch
	case .Type_Is_Guard:   return .Type_Is_Guard // TypeIs: narrowing in both branches
	case .Is_Callable:     return .Is_Not_Callable
	case .Is_Not_Callable: return .Is_Callable
	}
	return kind
}

