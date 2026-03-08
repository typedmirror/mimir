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
}

Guard :: struct {
	kind:         Guard_Kind,
	symbol_id:    binder.Symbol_ID,
	type_expr:    parser.Expr,
	branch_block: Block_ID,
	true_block:   Block_ID,
	false_block:  Block_ID,
	loc:          parser.Src_Loc,
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
					analyze_condition(s.test, bind_result, block.id, true_block, false_block, s.loc, &guards, allocator)
				}

			case ^parser.While_Stmt:
				true_block := find_succ_by_edge_kind(&block, .True_Branch)
				false_block := find_succ_by_edge_kind(&block, .False_Branch)
				if true_block != INVALID_BLOCK && false_block != INVALID_BLOCK {
					analyze_condition(s.test, bind_result, block.id, true_block, false_block, s.loc, &guards, allocator)
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
		// isinstance(x, T)
		if is_isinstance_call(e, bind_result) {
			if len(e.args) >= 2 {
				sym_id := expr_to_symbol(e.args[0], bind_result)
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
		}

	case ^parser.Compare_Expr:
		if len(e.ops) == 1 && len(e.comparators) == 1 {
			// x is None / x is not None
			if is_none_compare(e) {
				sym_id := expr_to_symbol(e.left, bind_result)
				if sym_id != binder.INVALID_SYMBOL {
					kind: Guard_Kind
					if e.ops[0] == .Is {
						kind = .Is_None
					} else {
						kind = .Is_Not_None
					}
					append(guards, Guard{
						kind         = kind,
						symbol_id    = sym_id,
						branch_block = branch_block,
						true_block   = true_block,
						false_block  = false_block,
						loc          = loc,
					})
				}
			}
			// None is x / None is not x (reversed)
			if is_none_compare_reversed(e) {
				sym_id := expr_to_symbol(e.comparators[0], bind_result)
				if sym_id != binder.INVALID_SYMBOL {
					kind: Guard_Kind
					if e.ops[0] == .Is {
						kind = .Is_None
					} else {
						kind = .Is_Not_None
					}
					append(guards, Guard{
						kind         = kind,
						symbol_id    = sym_id,
						branch_block = branch_block,
						true_block   = true_block,
						false_block  = false_block,
						loc          = loc,
					})
				}
			}
			// type(x) is T / type(x) is not T
			if is_type_compare(e, bind_result) {
				call := e.left.(^parser.Call_Expr)
				if call != nil && len(call.args) >= 1 {
					sym_id := expr_to_symbol(call.args[0], bind_result)
					if sym_id != binder.INVALID_SYMBOL {
						kind: Guard_Kind
						if e.ops[0] == .Is {
							kind = .Type_Is
						} else {
							kind = .Type_Is_Not
						}
						append(guards, Guard{
							kind         = kind,
							symbol_id    = sym_id,
							type_expr    = e.comparators[0],
							branch_block = branch_block,
							true_block   = true_block,
							false_block  = false_block,
							loc          = loc,
						})
					}
				}
			}
		}

	case ^parser.Name_Expr:
		// if x: (truthiness)
		sym_id := expr_to_symbol(expr, bind_result)
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

	case ^parser.Unary_Op_Expr:
		// if not x: → invert
		if e.op == .Not {
			// Recursively analyze and invert
			temp_guards := make([dynamic]Guard, 0, 4, allocator)
			analyze_condition(e.operand, bind_result, branch_block, true_block, false_block, loc, &temp_guards, allocator)
			for &g in temp_guards {
				g.kind = invert_guard_kind(g.kind)
				// Swap true/false blocks for inverted guards
				g.true_block, g.false_block = g.false_block, g.true_block
				append(guards, g)
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

expr_to_symbol :: proc(expr: parser.Expr, bind_result: ^binder.Bind_Result) -> binder.Symbol_ID {
	if expr == nil { return binder.INVALID_SYMBOL }
	#partial switch e in expr {
	case ^parser.Name_Expr:
		sym_id, ok := binder.get_ref(bind_result, rawptr(e))
		if ok {
			return sym_id
		}
		// For Store context names, search by name
		for &sym in bind_result.symbols {
			if sym.name == e.id {
				return sym.id
			}
		}
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
	}
	return kind
}

// ==================== Query Interface ====================

guards_for_block :: proc(guards: []Guard, block_id: Block_ID) -> []Guard {
	// Returns guards where true_block or false_block matches
	// Caller should filter further
	count := 0
	for &g in guards {
		if g.true_block == block_id || g.false_block == block_id {
			count += 1
		}
	}
	if count == 0 { return {} }

	// Since we can't allocate without an allocator, return full slice
	// Phase 4 will use a filtered view
	return guards
}
