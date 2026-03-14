package taint

import "core:mem"
import parser "mimir:parser"
import binder "mimir:binder"
import flow "mimir:flow"

// ==================== Types ====================

Taint_Label :: enum u8 {
	Unknown,    // not yet analyzed
	Untrusted,  // came from a source (user input, external data)
	Trusted,    // sanitized or known-safe (literal, type cast)
}

Taint_Info :: struct {
	label:       Taint_Label,
	source_loc:  parser.Src_Loc,
	source_desc: string,
}

Taint_Env :: struct {
	info: map[binder.Symbol_ID]Taint_Info,
}

// Alias_Info tracks variable aliasing for security/taint resolution.
// e.g., e = eval → {module="", name="eval"}, run = subprocess.run → {module="subprocess", name="run"}
Alias_Info :: struct {
	module: string,
	name:   string,
}

Taint_Context :: struct {
	cfg:          ^flow.CFG,
	bind_result:  ^binder.Bind_Result,
	import_map:   map[string]string,
	name_aliases: map[string]Alias_Info,
	envs:         []Taint_Env,
	violations:   [dynamic]Taint_Violation,
	summaries:    map[string]Taint_Summary,
	allocator:    mem.Allocator,
}

Taint_Violation :: struct {
	sink_loc:    parser.Src_Loc,
	source_loc:  parser.Src_Loc,
	source_desc: string,
	sink_desc:   string,
	rule_code:   string,
}

// ==================== BFS Driver ====================

analyze_taint :: proc(
	cfg: ^flow.CFG,
	bind_result: ^binder.Bind_Result,
	import_map: map[string]string,
	allocator: mem.Allocator,
	summaries: map[string]Taint_Summary,
	name_aliases: map[string]Alias_Info,
) -> []Taint_Violation {
	num_blocks := len(cfg.blocks)

	ctx := Taint_Context{
		cfg          = cfg,
		bind_result  = bind_result,
		import_map   = import_map,
		name_aliases = name_aliases,
		envs         = make([]Taint_Env, num_blocks, allocator),
		violations   = make([dynamic]Taint_Violation, 0, 8, allocator),
		summaries    = summaries,
		allocator    = allocator,
	}

	for i in 0 ..< num_blocks {
		ctx.envs[i] = Taint_Env{
			info = make(map[binder.Symbol_ID]Taint_Info, 16, allocator),
		}
	}

	if cfg.entry == flow.INVALID_BLOCK { return ctx.violations[:] }

	// Worklist fixpoint iteration — blocks are re-visited when taint env changes.
	// This ensures taint propagates through loops (back-edges).
	queue := make([dynamic]flow.Block_ID, 0, num_blocks, allocator)
	in_queue := make([]bool, num_blocks, allocator)
	old_envs := make([]Taint_Env, num_blocks, allocator)
	for i in 0 ..< num_blocks {
		old_envs[i] = Taint_Env{
			info = make(map[binder.Symbol_ID]Taint_Info, 16, allocator),
		}
	}

	entry_idx := int(cfg.entry) - 1
	if entry_idx >= 0 && entry_idx < num_blocks {
		append(&queue, cfg.entry)
		in_queue[entry_idx] = true
	}

	queue_head := 0
	for queue_head < len(queue) {
		block_id := queue[queue_head]
		queue_head += 1

		idx := int(block_id) - 1
		if idx < 0 || idx >= num_blocks { continue }
		in_queue[idx] = false

		block := flow.get_block(cfg, block_id)
		if block == nil || !block.is_reachable { continue }

		env := &ctx.envs[idx]
		for pred_id in block.preds {
			pred_idx := int(pred_id) - 1
			if pred_idx >= 0 && pred_idx < num_blocks {
				merge_taint_envs(env, &ctx.envs[pred_idx], allocator)
			}
		}

		for stmt in block.stmts {
			process_stmt(&ctx, env, stmt)
		}

		// Re-enqueue successors only if env changed (fixpoint check)
		if !taint_env_equal(env, &old_envs[idx]) {
			copy_taint_env(&old_envs[idx], env, allocator)
			for succ_id in block.succs {
				succ_idx := int(succ_id) - 1
				if succ_idx >= 0 && succ_idx < num_blocks && !in_queue[succ_idx] {
					append(&queue, succ_id)
					in_queue[succ_idx] = true
				}
			}
		}
	}

	// Deduplicate violations (blocks may be revisited during fixpoint)
	dedup_violations(&ctx.violations)

	return ctx.violations[:]
}

// ==================== Helpers ====================

max_taint :: proc(a, b: Taint_Label) -> Taint_Label {
	if a == .Untrusted || b == .Untrusted { return .Untrusted }
	if a == .Unknown || b == .Unknown { return .Unknown }
	return .Trusted
}

max_taint_info :: proc(a, b: Taint_Info) -> Taint_Info {
	if a.label == .Untrusted { return a }
	if b.label == .Untrusted { return b }
	if a.label == .Unknown { return a }
	if b.label == .Unknown { return b }
	return a
}

// taint_env_equal compares two taint envs for equality (by label only).
taint_env_equal :: proc(a, b: ^Taint_Env) -> bool {
	if len(a.info) != len(b.info) { return false }
	for sym_id, a_info in a.info {
		if b_info, ok := b.info[sym_id]; ok {
			if a_info.label != b_info.label { return false }
		} else {
			return false
		}
	}
	return true
}

// copy_taint_env replaces dst env with an exact copy of src.
copy_taint_env :: proc(dst, src: ^Taint_Env, allocator: mem.Allocator) {
	// Clear stale entries not in src
	keys_to_delete: [dynamic]binder.Symbol_ID
	keys_to_delete.allocator = context.temp_allocator
	for sym_id in dst.info {
		if sym_id not_in src.info {
			append(&keys_to_delete, sym_id)
		}
	}
	for k in keys_to_delete {
		delete_key(&dst.info, k)
	}
	// Copy all src entries
	for sym_id, info in src.info {
		dst.info[sym_id] = info
	}
}

// dedup_violations removes duplicate violations (same line+col+rule_code).
dedup_violations :: proc(violations: ^[dynamic]Taint_Violation) {
	if len(violations) <= 1 { return }
	write := 0
	for i := 0; i < len(violations); i += 1 {
		dup := false
		for j := 0; j < write; j += 1 {
			if violations[i].sink_loc.line == violations[j].sink_loc.line &&
			   violations[i].sink_loc.col == violations[j].sink_loc.col &&
			   violations[i].rule_code == violations[j].rule_code {
				dup = true
				break
			}
		}
		if !dup {
			violations[write] = violations[i]
			write += 1
		}
	}
	resize(violations, write)
}

expr_loc :: proc(expr: parser.Expr) -> parser.Src_Loc {
	if expr == nil { return {} }
	#partial switch e in expr {
	case ^parser.Call_Expr:        return e.loc
	case ^parser.Name_Expr:        return e.loc
	case ^parser.Attribute_Expr:   return e.loc
	case ^parser.Subscript_Expr:   return e.loc
	case ^parser.Bin_Op_Expr:      return e.loc
	case ^parser.Joined_Str:       return e.loc
	case ^parser.Formatted_Value:  return e.loc
	case ^parser.Constant_Expr:    return e.loc
	case ^parser.If_Expr:          return e.loc
	case ^parser.List_Expr:        return e.loc
	case ^parser.Tuple_Expr:       return e.loc
	case ^parser.Bool_Op_Expr:     return e.loc
	case ^parser.Unary_Op_Expr:    return e.loc
	case ^parser.Compare_Expr:     return e.loc
	case ^parser.Named_Expr:       return e.loc
	case ^parser.Starred_Expr:     return e.loc
	case ^parser.Dict_Expr:        return e.loc
	case ^parser.Set_Expr:         return e.loc
	case ^parser.Lambda_Expr:      return e.loc
	}
	return {}
}
