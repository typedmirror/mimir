package taint

import "core:mem"
import parser "mimir:parser"
import binder "mimir:binder"
import flow "mimir:flow"

// ==================== Taint Summary ====================

// Taint_Summary captures the taint behavior of a function.
// Built in pass 1, applied at call sites in pass 2.
Taint_Summary :: struct {
	scope_name:     string,        // function name (for lookup)
	propagates:     bool,          // param taint reaches return value
	always_tainted: bool,          // return is tainted regardless (body has source)
	source_desc:    string,        // when always_tainted: source description
	source_loc:     parser.Src_Loc, // when always_tainted: source location
}

// build_summaries extracts a taint summary for every function CFG in the module.
// Returns a map keyed by function name (scope_name).
build_summaries :: proc(
	cfgs: []flow.CFG,
	bind_result: ^binder.Bind_Result,
	import_map: map[string]string,
	allocator: mem.Allocator,
) -> map[string]Taint_Summary {
	summaries := make(map[string]Taint_Summary, 16, allocator)

	for &cfg in cfgs {
		// Skip module-level scope — only function CFGs get summaries
		scope := binder.result_get_scope(bind_result, cfg.scope_id)
		if scope == nil { continue }
		if scope.kind != .Function { continue }

		summary := build_summary_for_cfg(&cfg, bind_result, import_map, allocator)
		if len(summary.scope_name) > 0 {
			summaries[summary.scope_name] = summary
		}
	}

	return summaries
}

// build_summary_for_cfg analyzes a single function CFG to determine
// whether it propagates parameter taint or always returns tainted data.
build_summary_for_cfg :: proc(
	cfg: ^flow.CFG,
	bind_result: ^binder.Bind_Result,
	import_map: map[string]string,
	allocator: mem.Allocator,
) -> Taint_Summary {
	summary := Taint_Summary{
		scope_name = cfg.scope_name,
	}

	num_blocks := len(cfg.blocks)
	if num_blocks == 0 || cfg.entry == flow.INVALID_BLOCK {
		return summary
	}

	// Build initial env: all params marked as UNTRUSTED
	scope := binder.result_get_scope(bind_result, cfg.scope_id)
	if scope == nil { return summary }

	// Create taint context for BFS
	ctx := Taint_Context{
		cfg         = cfg,
		bind_result = bind_result,
		import_map  = import_map,
		envs        = make([]Taint_Env, num_blocks, allocator),
		violations  = make([dynamic]Taint_Violation, 0, 8, allocator),
		allocator   = allocator,
	}

	for i in 0 ..< num_blocks {
		ctx.envs[i] = Taint_Env{
			info = make(map[binder.Symbol_ID]Taint_Info, 16, allocator),
		}
	}

	// Inject params as UNTRUSTED in the entry block env
	entry_idx := int(cfg.entry) - 1
	if entry_idx < 0 || entry_idx >= num_blocks { return summary }

	for _, sym_id in scope.symbols {
		sym := binder.result_get_symbol(bind_result, sym_id)
		if sym == nil { continue }
		if .Is_Param not_in sym.flags { continue }

		ctx.envs[entry_idx].info[sym_id] = Taint_Info{
			label       = .Untrusted,
			source_loc  = sym.def_loc,
			source_desc = "param",
		}
	}

	// Run BFS (same logic as analyze_taint)
	queue := make([dynamic]flow.Block_ID, 0, num_blocks, allocator)
	visited := make([]bool, num_blocks, allocator)

	append(&queue, cfg.entry)

	for len(queue) > 0 {
		block_id := queue[0]
		ordered_remove(&queue, 0)

		idx := int(block_id) - 1
		if idx < 0 || idx >= num_blocks { continue }
		if visited[idx] { continue }
		visited[idx] = true

		block := flow.get_block(cfg, block_id)
		if block == nil || !block.is_reachable { continue }

		env := &ctx.envs[idx]
		for pred_id in block.preds {
			pred_idx := int(pred_id) - 1
			if pred_idx >= 0 && pred_idx < num_blocks && visited[pred_idx] {
				merge_taint_envs(env, &ctx.envs[pred_idx], allocator)
			}
		}

		for stmt in block.stmts {
			process_stmt(&ctx, env, stmt)
		}

		// Inspect return statements for summary extraction
		for stmt in block.stmts {
			if ret, ok := stmt.(^parser.Return_Stmt); ok && ret.value != nil {
				info := expr_taint(&ctx, env, ret.value)
				if info.label == .Untrusted {
					if info.source_desc == "param" {
						summary.propagates = true
					} else {
						summary.always_tainted = true
						summary.source_desc = info.source_desc
						summary.source_loc = info.source_loc
					}
				}
			}
		}

		for succ_id in block.succs {
			succ_idx := int(succ_id) - 1
			if succ_idx >= 0 && succ_idx < num_blocks && !visited[succ_idx] {
				append(&queue, succ_id)
			}
		}
	}

	return summary
}
