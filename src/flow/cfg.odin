package flow

import "core:mem"
import parser "mimir:parser"
import binder "mimir:binder"
import core "mimir:core"

// ==================== Types ====================

Block_ID :: distinct u32
INVALID_BLOCK :: Block_ID(0)

Edge_Kind :: enum u8 {
	Fallthrough,
	True_Branch,
	False_Branch,
	Exception,
	Finally_Entry,
	Break,
	Continue,
	Case_Match,
	Case_Default,
}

Block :: struct {
	id:           Block_ID,
	stmts:        [dynamic]parser.Stmt,
	succs:        [dynamic]Block_ID,
	preds:        [dynamic]Block_ID,
	edge_kinds:   [dynamic]Edge_Kind,
	is_reachable: bool,
}

CFG :: struct {
	blocks:     [dynamic]Block,
	entry:      Block_ID,
	exit:       Block_ID,
	scope_id:   binder.Scope_ID,
	scope_name: string,
}

Loop_Context :: struct {
	header: Block_ID,
	after:  Block_ID,
}

Try_Context :: struct {
	handlers: [dynamic]Block_ID,
	finally_block:  Block_ID,
}

CFG_Builder :: struct {
	cfg:         ^CFG,
	current:     Block_ID,
	loop_stack:  [dynamic]Loop_Context,
	try_stack:   [dynamic]Try_Context,
	bind_result: ^binder.Bind_Result,
	file_path:   string,
	allocator:   mem.Allocator,
	diagnostics: ^[dynamic]core.Diagnostic,
}

// ==================== CFG Construction ====================

new_block :: proc(cfg: ^CFG, allocator: mem.Allocator) -> Block_ID {
	id := Block_ID(u32(len(cfg.blocks)) + 1)
	append(&cfg.blocks, Block{
		id         = id,
		stmts      = make([dynamic]parser.Stmt, 0, 8, allocator),
		succs      = make([dynamic]Block_ID, 0, 4, allocator),
		preds      = make([dynamic]Block_ID, 0, 4, allocator),
		edge_kinds = make([dynamic]Edge_Kind, 0, 4, allocator),
	})
	return id
}

get_block :: proc(cfg: ^CFG, id: Block_ID) -> ^Block {
	idx := int(id) - 1
	if idx < 0 || idx >= len(cfg.blocks) {
		return nil
	}
	return &cfg.blocks[idx]
}

add_stmt :: proc(cfg: ^CFG, block_id: Block_ID, stmt: parser.Stmt) {
	blk := get_block(cfg, block_id)
	if blk != nil {
		append(&blk.stmts, stmt)
	}
}

add_edge :: proc(cfg: ^CFG, from, to: Block_ID, kind: Edge_Kind) {
	if from == INVALID_BLOCK || to == INVALID_BLOCK { return }
	blk := get_block(cfg, from)
	if blk != nil {
		append(&blk.succs, to)
		append(&blk.edge_kinds, kind)
	}
}

build_predecessors :: proc(cfg: ^CFG) {
	for &block in cfg.blocks {
		for succ_id in block.succs {
			succ := get_block(cfg, succ_id)
			if succ != nil {
				append(&succ.preds, block.id)
			}
		}
	}
}

// ==================== Entry Points ====================

build_cfg_for_stmts :: proc(
	stmts: []parser.Stmt,
	scope_id: binder.Scope_ID,
	scope_name: string,
	bind_result: ^binder.Bind_Result,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) -> CFG {
	cfg: CFG
	cfg.blocks = make([dynamic]Block, 0, 32, allocator)
	cfg.scope_id = scope_id
	cfg.scope_name = scope_name

	entry := new_block(&cfg, allocator)
	exit := new_block(&cfg, allocator)
	cfg.entry = entry
	cfg.exit = exit

	b := CFG_Builder{
		cfg         = &cfg,
		current     = entry,
		loop_stack  = make([dynamic]Loop_Context, 0, 4, allocator),
		try_stack   = make([dynamic]Try_Context, 0, 4, allocator),
		bind_result = bind_result,
		file_path   = file_path,
		allocator   = allocator,
		diagnostics = diagnostics,
	}

	result_block := process_stmts(&b, stmts)

	// If current block hasn't terminated, add fallthrough to exit
	if result_block != INVALID_BLOCK {
		add_edge(&cfg, result_block, exit, .Fallthrough)
	}

	build_predecessors(&cfg)
	return cfg
}

// ==================== Statement Processing ====================

process_stmts :: proc(b: ^CFG_Builder, stmts: []parser.Stmt) -> Block_ID {
	for stmt in stmts {
		if b.current == INVALID_BLOCK {
			// Dead code after terminator — report ALL unreachable stmts, not just first
			emit_unreachable(b, stmt)
			continue
		}
		b.current = process_stmt(b, stmt)
	}
	return b.current
}

process_stmt :: proc(b: ^CFG_Builder, stmt: parser.Stmt) -> Block_ID {
	#partial switch s in stmt {
	// Branching statements
	case ^parser.If_Stmt:
		return process_if(b, s, stmt)
	case ^parser.While_Stmt:
		return process_while(b, s, stmt)
	case ^parser.For_Stmt:
		return process_for(b, s, stmt)
	case ^parser.Async_For:
		return process_async_for(b, s, stmt)
	case ^parser.Match_Stmt:
		return process_match(b, s, stmt)
	case ^parser.With_Stmt:
		return process_with(b, s, stmt)
	case ^parser.Async_With:
		return process_async_with(b, s, stmt)
	case ^parser.Try_Stmt:
		return process_try(b, s, stmt)
	case ^parser.Try_Star:
		return process_try_star(b, s, stmt)

	// Terminating statements
	case ^parser.Return_Stmt:
		add_stmt(b.cfg, b.current, stmt)
		add_edge(b.cfg, b.current, b.cfg.exit, .Fallthrough)
		return INVALID_BLOCK
	case ^parser.Raise_Stmt:
		add_stmt(b.cfg, b.current, stmt)
		if len(b.try_stack) > 0 {
			ctx := &b.try_stack[len(b.try_stack) - 1]
			for handler in ctx.handlers {
				add_edge(b.cfg, b.current, handler, .Exception)
			}
			if ctx.finally_block != INVALID_BLOCK {
				add_edge(b.cfg, b.current, ctx.finally_block, .Finally_Entry)
			}
		} else {
			add_edge(b.cfg, b.current, b.cfg.exit, .Exception)
		}
		return INVALID_BLOCK
	case ^parser.Break_Stmt:
		add_stmt(b.cfg, b.current, stmt)
		if len(b.loop_stack) > 0 {
			ctx := &b.loop_stack[len(b.loop_stack) - 1]
			add_edge(b.cfg, b.current, ctx.after, .Break)
		}
		return INVALID_BLOCK
	case ^parser.Continue_Stmt:
		add_stmt(b.cfg, b.current, stmt)
		if len(b.loop_stack) > 0 {
			ctx := &b.loop_stack[len(b.loop_stack) - 1]
			add_edge(b.cfg, b.current, ctx.header, .Continue)
		}
		return INVALID_BLOCK

	// Assert False — terminates like raise
	case ^parser.Assert_Stmt:
		add_stmt(b.cfg, b.current, stmt)
		// assert False — always terminates (like raise AssertionError)
		if c, ok := s.test.(^parser.Constant_Expr); ok {
			if bval, bok := c.value.(bool); bok && !bval {
				add_edge(b.cfg, b.current, b.cfg.exit, .Exception)
				return INVALID_BLOCK
			}
		}
		// assert_never(...) — always terminates
		if call, ok := s.test.(^parser.Call_Expr); ok {
			if name, nok := call.func.(^parser.Name_Expr); nok {
				if name.id == "assert_never" {
					add_edge(b.cfg, b.current, b.cfg.exit, .Exception)
					return INVALID_BLOCK
				}
			}
		}
		return b.current

	// All straight-line statements
	case:
		add_stmt(b.cfg, b.current, stmt)
		return b.current
	}
}

// ==================== Branching Handlers ====================

process_if :: proc(b: ^CFG_Builder, s: ^parser.If_Stmt, stmt: parser.Stmt) -> Block_ID {
	// Add if_stmt to current block (condition evaluated here)
	add_stmt(b.cfg, b.current, stmt)
	cond_block := b.current

	merge := new_block(b.cfg, b.allocator)

	// True branch
	true_block := new_block(b.cfg, b.allocator)
	add_edge(b.cfg, cond_block, true_block, .True_Branch)
	b.current = true_block
	true_end := process_stmts(b, s.body)
	if true_end != INVALID_BLOCK {
		add_edge(b.cfg, true_end, merge, .Fallthrough)
	}

	// False branch
	if len(s.orelse) > 0 {
		false_block := new_block(b.cfg, b.allocator)
		add_edge(b.cfg, cond_block, false_block, .False_Branch)
		b.current = false_block
		false_end := process_stmts(b, s.orelse)
		if false_end != INVALID_BLOCK {
			add_edge(b.cfg, false_end, merge, .Fallthrough)
		}
	} else {
		add_edge(b.cfg, cond_block, merge, .False_Branch)
	}

	return merge
}

process_while :: proc(b: ^CFG_Builder, s: ^parser.While_Stmt, stmt: parser.Stmt) -> Block_ID {
	header := new_block(b.cfg, b.allocator)
	add_edge(b.cfg, b.current, header, .Fallthrough)

	after := new_block(b.cfg, b.allocator)

	// Add while_stmt to header (condition evaluated here)
	add_stmt(b.cfg, header, stmt)

	// Push loop context
	append(&b.loop_stack, Loop_Context{header = header, after = after})

	// Body
	body_block := new_block(b.cfg, b.allocator)
	add_edge(b.cfg, header, body_block, .True_Branch)
	b.current = body_block
	body_end := process_stmts(b, s.body)
	if body_end != INVALID_BLOCK {
		add_edge(b.cfg, body_end, header, .Fallthrough) // back edge
	}

	// Else clause
	if len(s.orelse) > 0 {
		else_block := new_block(b.cfg, b.allocator)
		add_edge(b.cfg, header, else_block, .False_Branch)
		b.current = else_block
		else_end := process_stmts(b, s.orelse)
		if else_end != INVALID_BLOCK {
			add_edge(b.cfg, else_end, after, .Fallthrough)
		}
	} else {
		add_edge(b.cfg, header, after, .False_Branch)
	}

	pop(&b.loop_stack)
	return after
}

process_for :: proc(b: ^CFG_Builder, s: ^parser.For_Stmt, stmt: parser.Stmt) -> Block_ID {
	header := new_block(b.cfg, b.allocator)
	add_edge(b.cfg, b.current, header, .Fallthrough)

	after := new_block(b.cfg, b.allocator)
	add_stmt(b.cfg, header, stmt)

	append(&b.loop_stack, Loop_Context{header = header, after = after})

	body_block := new_block(b.cfg, b.allocator)
	add_edge(b.cfg, header, body_block, .True_Branch)
	b.current = body_block
	body_end := process_stmts(b, s.body)
	if body_end != INVALID_BLOCK {
		add_edge(b.cfg, body_end, header, .Fallthrough)
	}

	if len(s.orelse) > 0 {
		else_block := new_block(b.cfg, b.allocator)
		add_edge(b.cfg, header, else_block, .False_Branch)
		b.current = else_block
		else_end := process_stmts(b, s.orelse)
		if else_end != INVALID_BLOCK {
			add_edge(b.cfg, else_end, after, .Fallthrough)
		}
	} else {
		add_edge(b.cfg, header, after, .False_Branch)
	}

	pop(&b.loop_stack)
	return after
}

process_async_for :: proc(b: ^CFG_Builder, s: ^parser.Async_For, stmt: parser.Stmt) -> Block_ID {
	header := new_block(b.cfg, b.allocator)
	add_edge(b.cfg, b.current, header, .Fallthrough)

	after := new_block(b.cfg, b.allocator)
	add_stmt(b.cfg, header, stmt)

	append(&b.loop_stack, Loop_Context{header = header, after = after})

	body_block := new_block(b.cfg, b.allocator)
	add_edge(b.cfg, header, body_block, .True_Branch)
	b.current = body_block
	body_end := process_stmts(b, s.body)
	if body_end != INVALID_BLOCK {
		add_edge(b.cfg, body_end, header, .Fallthrough)
	}

	if len(s.orelse) > 0 {
		else_block := new_block(b.cfg, b.allocator)
		add_edge(b.cfg, header, else_block, .False_Branch)
		b.current = else_block
		else_end := process_stmts(b, s.orelse)
		if else_end != INVALID_BLOCK {
			add_edge(b.cfg, else_end, after, .Fallthrough)
		}
	} else {
		add_edge(b.cfg, header, after, .False_Branch)
	}

	pop(&b.loop_stack)
	return after
}

process_match :: proc(b: ^CFG_Builder, s: ^parser.Match_Stmt, stmt: parser.Stmt) -> Block_ID {
	add_stmt(b.cfg, b.current, stmt)
	match_block := b.current

	after := new_block(b.cfg, b.allocator)

	for mc, i in s.cases {
		case_block := new_block(b.cfg, b.allocator)
		// Check if this is a wildcard/default case (Match_As with nil pattern and no guard)
		is_default := false
		if mc.guard == nil {
			#partial switch p in mc.pattern {
			case ^parser.Match_As:
				if p.pattern == nil {
					is_default = true
				}
			}
		}
		if is_default {
			add_edge(b.cfg, match_block, case_block, .Case_Default)
		} else {
			add_edge(b.cfg, match_block, case_block, .Case_Match)
		}

		b.current = case_block
		case_end := process_stmts(b, mc.body)
		if case_end != INVALID_BLOCK {
			add_edge(b.cfg, case_end, after, .Fallthrough)
		}
	}

	// If no default case, match_block can fall through to after
	has_default := false
	for mc in s.cases {
		if mc.guard == nil {
			#partial switch p in mc.pattern {
			case ^parser.Match_As:
				if p.pattern == nil {
					has_default = true
				}
			}
		}
	}
	if !has_default {
		add_edge(b.cfg, match_block, after, .Fallthrough)
	}

	return after
}

process_with :: proc(b: ^CFG_Builder, s: ^parser.With_Stmt, stmt: parser.Stmt) -> Block_ID {
	add_stmt(b.cfg, b.current, stmt)
	pre_block := b.current

	after := new_block(b.cfg, b.allocator)

	body_block := new_block(b.cfg, b.allocator)
	add_edge(b.cfg, pre_block, body_block, .Fallthrough)

	body_start_count := len(b.cfg.blocks)
	b.current = body_block
	body_end := process_stmts(b, s.body)
	if body_end != INVALID_BLOCK {
		add_edge(b.cfg, body_end, after, .Fallthrough)
	}
	// Exception edges from ALL body blocks for cleanup
	add_edge(b.cfg, body_block, after, .Exception)
	for i := body_start_count; i < len(b.cfg.blocks); i += 1 {
		body_block_id := Block_ID(i + 1) // 1-indexed
		add_edge(b.cfg, body_block_id, after, .Exception)
	}

	// Even if body terminates (return/raise), __exit__ always runs and may
	// suppress exceptions, making code after `with` potentially reachable.
	// Return the after-block so downstream code is not flagged as unreachable (F001).
	if body_end != INVALID_BLOCK {
		add_edge(b.cfg, body_end, after, .Fallthrough)
	}

	return after
}

process_async_with :: proc(b: ^CFG_Builder, s: ^parser.Async_With, stmt: parser.Stmt) -> Block_ID {
	add_stmt(b.cfg, b.current, stmt)
	pre_block := b.current

	after := new_block(b.cfg, b.allocator)

	body_block := new_block(b.cfg, b.allocator)
	add_edge(b.cfg, pre_block, body_block, .Fallthrough)

	body_start_count := len(b.cfg.blocks)
	b.current = body_block
	body_end := process_stmts(b, s.body)
	if body_end != INVALID_BLOCK {
		add_edge(b.cfg, body_end, after, .Fallthrough)
	}
	add_edge(b.cfg, body_block, after, .Exception)
	for i := body_start_count; i < len(b.cfg.blocks); i += 1 {
		body_block_id := Block_ID(i + 1)
		add_edge(b.cfg, body_block_id, after, .Exception)
	}

	return after
}

process_try :: proc(b: ^CFG_Builder, s: ^parser.Try_Stmt, stmt: parser.Stmt) -> Block_ID {
	add_stmt(b.cfg, b.current, stmt)
	pre_block := b.current

	after := new_block(b.cfg, b.allocator)
	has_finally := len(s.finalbody) > 0

	finally_block := INVALID_BLOCK
	if has_finally {
		finally_block = new_block(b.cfg, b.allocator)
	}

	// Build handler blocks first so we can push try context
	handler_blocks := make([dynamic]Block_ID, 0, len(s.handlers), b.allocator)
	for _ in s.handlers {
		append(&handler_blocks, new_block(b.cfg, b.allocator))
	}

	// Push try context
	try_ctx := Try_Context{
		handlers = handler_blocks,
		finally_block  = finally_block,
	}
	append(&b.try_stack, try_ctx)

	// Try body
	try_body := new_block(b.cfg, b.allocator)
	add_edge(b.cfg, pre_block, try_body, .Fallthrough)

	// Exception edges from try body entry to each handler
	for hb in handler_blocks {
		add_edge(b.cfg, try_body, hb, .Exception)
	}

	body_start_count := len(b.cfg.blocks)
	b.current = try_body
	try_end := process_stmts(b, s.body)

	// Add exception edges from ALL blocks created during body processing
	// (try body may contain if/for/while that create new blocks)
	for i := body_start_count; i < len(b.cfg.blocks); i += 1 {
		body_block_id := Block_ID(i + 1) // 1-indexed
		for hb in handler_blocks {
			add_edge(b.cfg, body_block_id, hb, .Exception)
		}
	}

	pop(&b.try_stack)

	// Determine where try body falls through to
	if len(s.orelse) > 0 {
		// Try succeeded → else block
		else_block := new_block(b.cfg, b.allocator)
		if try_end != INVALID_BLOCK {
			add_edge(b.cfg, try_end, else_block, .Fallthrough)
		}
		b.current = else_block
		else_end := process_stmts(b, s.orelse)
		if else_end != INVALID_BLOCK {
			if has_finally {
				add_edge(b.cfg, else_end, finally_block, .Finally_Entry)
			} else {
				add_edge(b.cfg, else_end, after, .Fallthrough)
			}
		}
	} else {
		if try_end != INVALID_BLOCK {
			if has_finally {
				add_edge(b.cfg, try_end, finally_block, .Finally_Entry)
			} else {
				add_edge(b.cfg, try_end, after, .Fallthrough)
			}
		}
	}

	// Process each handler, track if all handlers terminate
	all_handlers_terminate := len(s.handlers) > 0
	for handler, i in s.handlers {
		hb := handler_blocks[i]
		b.current = hb
		handler_end := process_stmts(b, handler.body)
		if handler_end != INVALID_BLOCK {
			all_handlers_terminate = false
			if has_finally {
				add_edge(b.cfg, handler_end, finally_block, .Finally_Entry)
			} else {
				add_edge(b.cfg, handler_end, after, .Fallthrough)
			}
		}
	}

	// Process finally
	if has_finally {
		b.current = finally_block
		finally_end := process_stmts(b, s.finalbody)
		if finally_end != INVALID_BLOCK {
			add_edge(b.cfg, finally_end, after, .Fallthrough)
		}
	}

	// If try body terminates (return/raise) AND all handlers terminate,
	// no path reaches 'after'. Return INVALID_BLOCK to prevent false F002.
	// Pattern: try: return X; except E: return Y
	if try_end == INVALID_BLOCK && all_handlers_terminate && !has_finally {
		return INVALID_BLOCK
	}

	return after
}

process_try_star :: proc(b: ^CFG_Builder, s: ^parser.Try_Star, stmt: parser.Stmt) -> Block_ID {
	// Same structure as try — except* handlers can match multiple
	add_stmt(b.cfg, b.current, stmt)
	pre_block := b.current

	after := new_block(b.cfg, b.allocator)
	has_finally := len(s.finalbody) > 0

	finally_block := INVALID_BLOCK
	if has_finally {
		finally_block = new_block(b.cfg, b.allocator)
	}

	handler_blocks := make([dynamic]Block_ID, 0, len(s.handlers), b.allocator)
	for _ in s.handlers {
		append(&handler_blocks, new_block(b.cfg, b.allocator))
	}

	try_ctx := Try_Context{
		handlers = handler_blocks,
		finally_block  = finally_block,
	}
	append(&b.try_stack, try_ctx)

	try_body := new_block(b.cfg, b.allocator)
	add_edge(b.cfg, pre_block, try_body, .Fallthrough)

	for hb in handler_blocks {
		add_edge(b.cfg, try_body, hb, .Exception)
	}

	body_start_count := len(b.cfg.blocks)
	b.current = try_body
	try_end := process_stmts(b, s.body)

	// Add exception edges from ALL blocks created during body processing
	for i := body_start_count; i < len(b.cfg.blocks); i += 1 {
		body_block_id := Block_ID(i + 1)
		for hb in handler_blocks {
			add_edge(b.cfg, body_block_id, hb, .Exception)
		}
	}

	pop(&b.try_stack)

	if len(s.orelse) > 0 {
		else_block := new_block(b.cfg, b.allocator)
		if try_end != INVALID_BLOCK {
			add_edge(b.cfg, try_end, else_block, .Fallthrough)
		}
		b.current = else_block
		else_end := process_stmts(b, s.orelse)
		if else_end != INVALID_BLOCK {
			if has_finally {
				add_edge(b.cfg, else_end, finally_block, .Finally_Entry)
			} else {
				add_edge(b.cfg, else_end, after, .Fallthrough)
			}
		}
	} else {
		if try_end != INVALID_BLOCK {
			if has_finally {
				add_edge(b.cfg, try_end, finally_block, .Finally_Entry)
			} else {
				add_edge(b.cfg, try_end, after, .Fallthrough)
			}
		}
	}

	for handler, i in s.handlers {
		hb := handler_blocks[i]
		b.current = hb
		handler_end := process_stmts(b, handler.body)
		if handler_end != INVALID_BLOCK {
			if has_finally {
				add_edge(b.cfg, handler_end, finally_block, .Finally_Entry)
			} else {
				add_edge(b.cfg, handler_end, after, .Fallthrough)
			}
		}
	}

	if has_finally {
		b.current = finally_block
		finally_end := process_stmts(b, s.finalbody)
		if finally_end != INVALID_BLOCK {
			add_edge(b.cfg, finally_end, after, .Fallthrough)
		}
	}

	return after
}

// ==================== Reachability ====================

compute_reachability :: proc(cfg: ^CFG) {
	if cfg.entry == INVALID_BLOCK { return }

	entry := get_block(cfg, cfg.entry)
	if entry == nil { return }
	entry.is_reachable = true

	// BFS
	queue := make([dynamic]Block_ID, 0, len(cfg.blocks))
	defer delete(queue)
	append(&queue, cfg.entry)

	queue_head := 0
	for queue_head < len(queue) {
		block_id := queue[queue_head]
		queue_head += 1

		blk := get_block(cfg, block_id)
		if blk == nil { continue }

		for succ_id in blk.succs {
			succ := get_block(cfg, succ_id)
			if succ != nil && !succ.is_reachable {
				succ.is_reachable = true
				append(&queue, succ_id)
			}
		}
	}
}

// ==================== Diagnostics ====================

emit_unreachable :: proc(b: ^CFG_Builder, stmt: parser.Stmt) {
	loc := stmt_loc(stmt)
	if loc.line == 0 { return }

	// Suppress F001 at module scope — module-level unreachable code after raise is common
	if b.cfg.scope_name == "<module>" { return }

	// Suppress for yield/yield_from after raise — common generator idiom
	// (yield makes the function a generator even though it's unreachable)
	if expr_stmt, ok := stmt.(^parser.Expr_Stmt); ok {
		#partial switch _ in expr_stmt.value {
		case ^parser.Yield_Expr, ^parser.Yield_From_Expr:
			return
		}
	}

	// Suppress for return NotImplemented — common dunder pattern
	if ret_stmt, ok := stmt.(^parser.Return_Stmt); ok {
		if ret_stmt.value != nil {
			if name, nok := ret_stmt.value.(^parser.Name_Expr); nok {
				if name.id == "NotImplemented" { return }
			}
		}
	}

	append(b.diagnostics, core.Diagnostic{
		severity = .Error,
		location = core.Location{
			file   = b.file_path,
			line   = int(loc.line),
			column = int(loc.col),
		},
		what = "unreachable code",
		why  = "code after return, raise, break, or continue will never execute",
		fix  = "remove the unreachable code or restructure control flow",
		code = "F001",
	})
}

check_missing_return :: proc(cfg: ^CFG, scope_name: string, has_return_annotation: bool, has_any_return: bool, file_path: string, def_loc: parser.Src_Loc, diagnostics: ^[dynamic]core.Diagnostic) {
	// Only check functions that have a return annotation or at least one explicit return
	if !has_return_annotation && !has_any_return { return }

	exit := get_block(cfg, cfg.exit)
	if exit == nil { return }

	// Check if any predecessor of exit reaches it via fallthrough WITHOUT a return as last stmt
	for pred_id in exit.preds {
		pred := get_block(cfg, pred_id)
		if pred == nil || !pred.is_reachable { continue }

		// Check edge kind from pred to exit
		for succ_id, i in pred.succs {
			if succ_id == cfg.exit {
				kind := pred.edge_kinds[i]
				if kind == .Fallthrough {
					// Check if block ends with a return — if so, this is a return edge, not missing
					if block_ends_with_return(pred) {
						continue
					}
					// Empty join block: check if ALL predecessors end with return/never
					// Handles post-if/else (2 preds) and post-match (N preds) join blocks
					if len(pred.stmts) == 0 && len(pred.preds) >= 2 {
						all_preds_return := true
						for pp_id in pred.preds {
							pp := get_block(cfg, pp_id)
							if pp == nil || !pp.is_reachable { continue }
							if !block_ends_with_return(pp) {
								all_preds_return = false
								break
							}
						}
						if all_preds_return { continue }
					}
					// This path reaches exit without return
					append(diagnostics, core.Diagnostic{
						severity = .Error,
						location = core.Location{
							file   = file_path,
							line   = int(def_loc.line),
							column = int(def_loc.col),
						},
						what = "missing return statement",
						why  = "not all code paths return a value",
						fix  = "add a return statement at the end of the function",
						code = "F002",
					})
					return // One diagnostic per function
				}
			}
		}
	}
}

block_ends_with_return :: proc(blk: ^Block) -> bool {
	if len(blk.stmts) == 0 { return false }
	last := blk.stmts[len(blk.stmts) - 1]
	#partial switch s in last {
	case ^parser.Return_Stmt:
		return true
	case ^parser.Raise_Stmt:
		return true
	case ^parser.Assert_Stmt:
		// assert False — always terminates
		if c, ok := s.test.(^parser.Constant_Expr); ok {
			if bval, bok := c.value.(bool); bok && !bval {
				return true
			}
		}
		// assert_never(...) or similar — name contains "never" or "assert"
		if call, ok := s.test.(^parser.Call_Expr); ok {
			if name, nok := call.func.(^parser.Name_Expr); nok {
				if name.id == "assert_never" { return true }
			}
		}
	case ^parser.Expr_Stmt:
		// sys.exit(), exit(), or other known never-return calls as expression statement
		if call, ok := s.value.(^parser.Call_Expr); ok {
			#partial switch fn in call.func {
			case ^parser.Name_Expr:
				switch fn.id {
				case "exit", "quit", "_exit", "abort", "assert_never", "no_return":
					return true
				}
			case ^parser.Attribute_Expr:
				switch fn.attr {
				case "exit", "_exit", "abort", "assert_never", "skip", "fail", "xfail":
					return true
				}
			}
		}
	case ^parser.Match_Stmt:
		// Exhaustive match: if every case arm ends with return, the match covers all paths
		if len(s.cases) > 0 {
			all_return := true
			for mc in s.cases {
				case_returns := false
				if len(mc.body) > 0 {
					last_stmt := mc.body[len(mc.body) - 1]
					#partial switch ls in last_stmt {
					case ^parser.Return_Stmt: case_returns = true
					case ^parser.Raise_Stmt: case_returns = true
					case ^parser.Expr_Stmt:
						if call, cok := ls.value.(^parser.Call_Expr); cok {
							#partial switch fn in call.func {
							case ^parser.Name_Expr:
								if fn.id == "exit" || fn.id == "assert_never" { case_returns = true }
							case ^parser.Attribute_Expr:
								if fn.attr == "exit" { case_returns = true }
							}
						}
					}
				}
				if !case_returns { all_return = false; break }
			}
			if all_return { return true }
		}
	}
	return false
}

// ==================== Helpers ====================

stmt_loc :: proc(stmt: parser.Stmt) -> parser.Src_Loc {
	switch s in stmt {
	case ^parser.Func_Def:          return s.loc
	case ^parser.Async_Func_Def:    return s.loc
	case ^parser.Class_Def:         return s.loc
	case ^parser.Return_Stmt:       return s.loc
	case ^parser.Delete_Stmt:       return s.loc
	case ^parser.Assign:            return s.loc
	case ^parser.Aug_Assign:        return s.loc
	case ^parser.Ann_Assign:        return s.loc
	case ^parser.For_Stmt:          return s.loc
	case ^parser.Async_For:         return s.loc
	case ^parser.While_Stmt:        return s.loc
	case ^parser.If_Stmt:           return s.loc
	case ^parser.With_Stmt:         return s.loc
	case ^parser.Async_With:        return s.loc
	case ^parser.Match_Stmt:        return s.loc
	case ^parser.Raise_Stmt:        return s.loc
	case ^parser.Try_Stmt:          return s.loc
	case ^parser.Try_Star:          return s.loc
	case ^parser.Assert_Stmt:       return s.loc
	case ^parser.Import_Stmt:       return s.loc
	case ^parser.Import_From:       return s.loc
	case ^parser.Global_Stmt:       return s.loc
	case ^parser.Nonlocal_Stmt:     return s.loc
	case ^parser.Expr_Stmt:         return s.loc
	case ^parser.Pass_Stmt:         return s.loc
	case ^parser.Break_Stmt:        return s.loc
	case ^parser.Continue_Stmt:     return s.loc
	case ^parser.Type_Alias_Stmt:   return s.loc
	}
	return {}
}

block_end_loc :: proc(blk: ^Block) -> parser.Src_Loc {
	if len(blk.stmts) > 0 {
		return stmt_loc(blk.stmts[len(blk.stmts) - 1])
	}
	return {}
}

total_blocks :: proc(result: ^Flow_Result) -> int {
	count := 0
	for &cfg in result.cfgs {
		count += len(cfg.blocks)
	}
	return count
}
