package flow

import "core:mem"
import parser "mimir:parser"
import binder "mimir:binder"

// ==================== Types ====================

Def_ID :: distinct u32
INVALID_DEF :: Def_ID(0)

Def_Point :: struct {
	id:        Def_ID,
	symbol_id: binder.Symbol_ID,
	block_id:  Block_ID,
	stmt_idx:  int,
	loc:       parser.Src_Loc,
}

DFG :: struct {
	defs:     [dynamic]Def_Point,
	gen:      []Reaching_Set,
	kill:     []Reaching_Set,
	reaching: []Reaching_Set,
	out:      []Reaching_Set,
}

Reaching_Set :: distinct map[Def_ID]struct{}

// ==================== Definition Collection ====================

collect_definitions :: proc(cfg: ^CFG, bind_result: ^binder.Bind_Result, allocator: mem.Allocator) -> DFG {
	dfg: DFG
	dfg.defs = make([dynamic]Def_Point, 0, 64, allocator)

	num_blocks := len(cfg.blocks)
	dfg.gen      = make([]Reaching_Set, num_blocks, allocator)
	dfg.kill     = make([]Reaching_Set, num_blocks, allocator)
	dfg.reaching = make([]Reaching_Set, num_blocks, allocator)
	dfg.out      = make([]Reaching_Set, num_blocks, allocator)

	for i in 0..<num_blocks {
		dfg.gen[i]      = Reaching_Set(make(map[Def_ID]struct{}, 8, allocator))
		dfg.kill[i]     = Reaching_Set(make(map[Def_ID]struct{}, 8, allocator))
		dfg.reaching[i] = Reaching_Set(make(map[Def_ID]struct{}, 8, allocator))
		dfg.out[i]      = Reaching_Set(make(map[Def_ID]struct{}, 8, allocator))
	}

	// Add function parameter definitions at entry block
	scope := binder.result_get_scope(bind_result, cfg.scope_id)
	if scope != nil && (scope.kind == .Function || scope.kind == .Lambda) {
		for name, sym_id in scope.symbols {
			sym := binder.result_get_symbol(bind_result, sym_id)
			if sym != nil && .Is_Param in sym.flags {
				add_def(&dfg, sym_id, cfg.entry, -1, sym.def_loc, allocator)
			}
		}
	}

	// Walk blocks for definition-creating statements
	for &block in cfg.blocks {
		for stmt, stmt_idx in block.stmts {
			extract_defs_from_stmt(&dfg, stmt, bind_result, block.id, stmt_idx, allocator)
		}
	}

	return dfg
}

add_def :: proc(dfg: ^DFG, symbol_id: binder.Symbol_ID, block_id: Block_ID, stmt_idx: int, loc: parser.Src_Loc, allocator: mem.Allocator) -> Def_ID {
	id := Def_ID(u32(len(dfg.defs)) + 1)
	append(&dfg.defs, Def_Point{
		id        = id,
		symbol_id = symbol_id,
		block_id  = block_id,
		stmt_idx  = stmt_idx,
		loc       = loc,
	})
	return id
}

extract_defs_from_stmt :: proc(dfg: ^DFG, stmt: parser.Stmt, bind_result: ^binder.Bind_Result, block_id: Block_ID, stmt_idx: int, allocator: mem.Allocator) {
	#partial switch s in stmt {
	case ^parser.Assign:
		for target in s.targets {
			extract_def_target(dfg, target, bind_result, block_id, stmt_idx, allocator)
		}
	case ^parser.Aug_Assign:
		extract_def_target(dfg, s.target, bind_result, block_id, stmt_idx, allocator)
	case ^parser.Ann_Assign:
		if s.value != nil {
			extract_def_target(dfg, s.target, bind_result, block_id, stmt_idx, allocator)
		}
	case ^parser.For_Stmt:
		extract_def_target(dfg, s.target, bind_result, block_id, stmt_idx, allocator)
	case ^parser.Async_For:
		extract_def_target(dfg, s.target, bind_result, block_id, stmt_idx, allocator)
	case ^parser.With_Stmt:
		for item in s.items {
			if item.optional_vars != nil {
				extract_def_target(dfg, item.optional_vars, bind_result, block_id, stmt_idx, allocator)
			}
		}
	case ^parser.Async_With:
		for item in s.items {
			if item.optional_vars != nil {
				extract_def_target(dfg, item.optional_vars, bind_result, block_id, stmt_idx, allocator)
			}
		}
	case ^parser.Import_Stmt:
		for alias in s.names {
			name := alias.asname if len(alias.asname) > 0 else alias.name
			sym_id := find_symbol_in_scope(bind_result, name, block_id, dfg)
			if sym_id != binder.INVALID_SYMBOL {
				add_def(dfg, sym_id, block_id, stmt_idx, alias.loc, allocator)
			}
		}
	case ^parser.Import_From:
		for alias in s.names {
			name := alias.asname if len(alias.asname) > 0 else alias.name
			sym_id := find_symbol_in_scope(bind_result, name, block_id, dfg)
			if sym_id != binder.INVALID_SYMBOL {
				add_def(dfg, sym_id, block_id, stmt_idx, alias.loc, allocator)
			}
		}
	case ^parser.Func_Def:
		sym_id := find_symbol_in_scope(bind_result, s.name, block_id, dfg)
		if sym_id != binder.INVALID_SYMBOL {
			add_def(dfg, sym_id, block_id, stmt_idx, s.loc, allocator)
		}
	case ^parser.Async_Func_Def:
		sym_id := find_symbol_in_scope(bind_result, s.name, block_id, dfg)
		if sym_id != binder.INVALID_SYMBOL {
			add_def(dfg, sym_id, block_id, stmt_idx, s.loc, allocator)
		}
	case ^parser.Class_Def:
		sym_id := find_symbol_in_scope(bind_result, s.name, block_id, dfg)
		if sym_id != binder.INVALID_SYMBOL {
			add_def(dfg, sym_id, block_id, stmt_idx, s.loc, allocator)
		}
	}
}

extract_def_target :: proc(dfg: ^DFG, expr: parser.Expr, bind_result: ^binder.Bind_Result, block_id: Block_ID, stmt_idx: int, allocator: mem.Allocator) {
	if expr == nil { return }
	#partial switch e in expr {
	case ^parser.Name_Expr:
		// Look up in binder refs
		sym_id, ok := binder.get_ref(bind_result, rawptr(e))
		if !ok {
			// Try finding by name in scope
			sym_id = find_symbol_in_scope(bind_result, e.id, block_id, dfg)
		}
		if sym_id != binder.INVALID_SYMBOL {
			add_def(dfg, sym_id, block_id, stmt_idx, e.loc, allocator)
		}
	case ^parser.Tuple_Expr:
		for elt in e.elts { extract_def_target(dfg, elt, bind_result, block_id, stmt_idx, allocator) }
	case ^parser.List_Expr:
		for elt in e.elts { extract_def_target(dfg, elt, bind_result, block_id, stmt_idx, allocator) }
	case ^parser.Starred_Expr:
		extract_def_target(dfg, e.value, bind_result, block_id, stmt_idx, allocator)
	}
}

// Find a symbol by name using the CFG's scope
find_symbol_in_scope :: proc(bind_result: ^binder.Bind_Result, name: string, block_id: Block_ID, dfg: ^DFG) -> binder.Symbol_ID {
	// Linear scan through symbols — sufficient for correctness
	for &sym in bind_result.symbols {
		if sym.name == name {
			return sym.id
		}
	}
	return binder.INVALID_SYMBOL
}

// ==================== GEN/KILL Computation ====================

compute_gen_kill :: proc(dfg: ^DFG, cfg: ^CFG) {
	for &def in dfg.defs {
		block_idx := int(def.block_id) - 1
		if block_idx < 0 || block_idx >= len(cfg.blocks) { continue }

		// Add to GEN (may be overwritten by later def of same symbol below)
		(^map[Def_ID]struct{})(&dfg.gen[block_idx])^[def.id] = {}

		// Kill all other defs of the same symbol in OTHER blocks
		for &other in dfg.defs {
			if other.id != def.id && other.symbol_id == def.symbol_id {
				(^map[Def_ID]struct{})(&dfg.kill[block_idx])^[other.id] = {}
			}
		}
	}

	// Only the LAST def of each symbol per block should be in GEN.
	// Remove earlier defs of the same symbol within the same block.
	for &def in dfg.defs {
		block_idx := int(def.block_id) - 1
		if block_idx < 0 || block_idx >= len(cfg.blocks) { continue }

		// Check if a later def of the same symbol exists in the same block
		for &later in dfg.defs {
			if later.symbol_id == def.symbol_id && later.block_id == def.block_id &&
			   later.stmt_idx > def.stmt_idx {
				// A later def kills this one within the block — remove from GEN
				gen_map := (^map[Def_ID]struct{})(&dfg.gen[block_idx])
				delete_key(gen_map, def.id)
				break
			}
		}
	}
}

// ==================== Worklist Algorithm ====================

compute_reaching :: proc(dfg: ^DFG, cfg: ^CFG, allocator: mem.Allocator) {
	num_blocks := len(cfg.blocks)
	if num_blocks == 0 { return }

	// Initialize worklist with all blocks
	worklist := make([dynamic]Block_ID, 0, num_blocks, allocator)
	in_worklist := make([]bool, num_blocks, allocator)

	for &block in cfg.blocks {
		if block.is_reachable {
			append(&worklist, block.id)
			in_worklist[int(block.id) - 1] = true
		}
	}

	wl_head := 0
	for wl_head < len(worklist) {
		block_id := worklist[wl_head]
		wl_head += 1
		block_idx := int(block_id) - 1
		in_worklist[block_idx] = false

		blk := get_block(cfg, block_id)
		if blk == nil { continue }

		// IN[B] = union of OUT[pred] for each predecessor
		new_in := Reaching_Set(make(map[Def_ID]struct{}, 16, allocator))
		for pred_id in blk.preds {
			pred_idx := int(pred_id) - 1
			if pred_idx >= 0 && pred_idx < num_blocks {
				for def_id in (map[Def_ID]struct{})(dfg.out[pred_idx]) {
					(^map[Def_ID]struct{})(&new_in)^[def_id] = {}
				}
			}
		}

		// OUT[B] = GEN[B] | (IN[B] - KILL[B])
		new_out := Reaching_Set(make(map[Def_ID]struct{}, 16, allocator))

		// Add GEN
		for def_id in (map[Def_ID]struct{})(dfg.gen[block_idx]) {
			(^map[Def_ID]struct{})(&new_out)^[def_id] = {}
		}

		// Add IN - KILL
		for def_id in (map[Def_ID]struct{})(new_in) {
			if def_id not_in (map[Def_ID]struct{})(dfg.kill[block_idx]) {
				(^map[Def_ID]struct{})(&new_out)^[def_id] = {}
			}
		}

		// Check if OUT changed
		changed := len((map[Def_ID]struct{})(new_out)) != len((map[Def_ID]struct{})(dfg.out[block_idx]))
		if !changed {
			for def_id in (map[Def_ID]struct{})(new_out) {
				if def_id not_in (map[Def_ID]struct{})(dfg.out[block_idx]) {
					changed = true
					break
				}
			}
		}

		dfg.reaching[block_idx] = new_in
		dfg.out[block_idx] = new_out

		if changed {
			for succ_id in blk.succs {
				succ_idx := int(succ_id) - 1
				if succ_idx >= 0 && succ_idx < num_blocks && !in_worklist[succ_idx] {
					append(&worklist, succ_id)
					in_worklist[succ_idx] = true
				}
			}
		}
	}
}

// ==================== Query Interface ====================

get_def :: proc(dfg: ^DFG, id: Def_ID) -> ^Def_Point {
	idx := int(id) - 1
	if idx < 0 || idx >= len(dfg.defs) {
		return nil
	}
	return &dfg.defs[idx]
}

defs_reaching_use :: proc(dfg: ^DFG, symbol_id: binder.Symbol_ID, block_id: Block_ID, stmt_idx: int, allocator: mem.Allocator) -> []Def_ID {
	block_idx := int(block_id) - 1
	if block_idx < 0 || block_idx >= len(dfg.reaching) {
		return {}
	}

	result := make([dynamic]Def_ID, 0, 8, allocator)

	// Start with reaching set at block entry
	for def_id in (map[Def_ID]struct{})(dfg.reaching[block_idx]) {
		def := get_def(dfg, def_id)
		if def != nil && def.symbol_id == symbol_id {
			append(&result, def_id)
		}
	}

	// Remove defs killed by earlier statements in this block,
	// add defs generated by earlier statements
	for &def in dfg.defs {
		if def.block_id == block_id && def.stmt_idx < stmt_idx && def.symbol_id == symbol_id {
			// This def in the same block before our use kills all prior reaching defs of same symbol
			clear(&result)
			append(&result, def.id)
		}
	}

	return result[:]
}
