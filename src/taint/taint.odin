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

Taint_Context :: struct {
	cfg:         ^flow.CFG,
	bind_result: ^binder.Bind_Result,
	import_map:  map[string]string,
	envs:        []Taint_Env,
	violations:  [dynamic]Taint_Violation,
	allocator:   mem.Allocator,
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
) -> []Taint_Violation {
	num_blocks := len(cfg.blocks)

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

	if cfg.entry == flow.INVALID_BLOCK { return ctx.violations[:] }

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

		for succ_id in block.succs {
			succ_idx := int(succ_id) - 1
			if succ_idx >= 0 && succ_idx < num_blocks && !visited[succ_idx] {
				append(&queue, succ_id)
			}
		}
	}

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
