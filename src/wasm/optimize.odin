package wasm

import "core:mem"

// WASM Optimization Passes — run on WASM_Module IR before emission.
// Passes: constant folding, dead code elimination, peephole.

// Run all optimization passes on a module.
optimize_module :: proc(module: ^WASM_Module, allocator: mem.Allocator) {
	for &func in module.functions {
		optimize_function(&func, allocator)
	}
}

optimize_function :: proc(func: ^WASM_Function, allocator: mem.Allocator) {
	// Run passes in order. Each pass may enable opportunities for later passes.
	// Max 3 iterations for convergence.
	for round in 0..<3 {
		changed := false
		changed = constant_fold(&func.body, allocator) || changed
		changed = dead_code_eliminate(&func.body, allocator) || changed
		changed = peephole_optimize(&func.body, allocator) || changed
		if !changed { break }
	}
}

// === Pass 1: Constant Folding ===
// i32.const A; i32.const B; i32.add → i32.const (A+B)

constant_fold :: proc(body: ^[dynamic]WASM_Instruction, allocator: mem.Allocator) -> bool {
	changed := false
	if len(body^) < 3 { return false }

	out := make([dynamic]WASM_Instruction, 0, len(body^), allocator)
	i := 0
	for i < len(body^) {
		if i + 2 < len(body^) {
			a := body[i]
			b := body[i + 1]
			op := body[i + 2]

			// i32 constant folding
			if a.kind == .I32_Const && b.kind == .I32_Const {
				folded: i32
				did_fold := true
				#partial switch op.kind {
				case .I32_Add: folded = a.i32_val + b.i32_val
				case .I32_Sub: folded = a.i32_val - b.i32_val
				case .I32_Mul: folded = a.i32_val * b.i32_val
				case .I32_And: folded = a.i32_val & b.i32_val
				case .I32_Or:  folded = a.i32_val | b.i32_val
				case .I32_Xor: folded = a.i32_val ~ b.i32_val
				case .I32_Shl: folded = a.i32_val << u32(b.i32_val & 31)
				case .I32_Shr_S: folded = a.i32_val >> u32(b.i32_val & 31)
				case .I32_Div_S:
					if b.i32_val != 0 { folded = a.i32_val / b.i32_val } else { did_fold = false }
				case .I32_Rem_S:
					if b.i32_val != 0 { folded = a.i32_val %% b.i32_val } else { did_fold = false }
				// i32 comparisons
				case .I32_Eq:   folded = 1 if a.i32_val == b.i32_val else 0
				case .I32_Ne:   folded = 1 if a.i32_val != b.i32_val else 0
				case .I32_Lt_S: folded = 1 if a.i32_val < b.i32_val else 0
				case .I32_Gt_S: folded = 1 if a.i32_val > b.i32_val else 0
				case .I32_Le_S: folded = 1 if a.i32_val <= b.i32_val else 0
				case .I32_Ge_S: folded = 1 if a.i32_val >= b.i32_val else 0
				case:
					did_fold = false
				}
				if did_fold {
					append(&out, WASM_Instruction{kind = .I32_Const, i32_val = folded})
					i += 3
					changed = true
					continue
				}
			}

			// f64 constant folding
			if a.kind == .F64_Const && b.kind == .F64_Const {
				folded: f64
				did_fold := true
				#partial switch op.kind {
				case .F64_Add: folded = a.f64_val + b.f64_val
				case .F64_Sub: folded = a.f64_val - b.f64_val
				case .F64_Mul: folded = a.f64_val * b.f64_val
				case .F64_Div:
					if b.f64_val != 0 { folded = a.f64_val / b.f64_val } else { did_fold = false }
				case .F64_Min: folded = a.f64_val if a.f64_val < b.f64_val else b.f64_val
				case .F64_Max: folded = a.f64_val if a.f64_val > b.f64_val else b.f64_val
				case:
					did_fold = false
				}
				if did_fold {
					append(&out, WASM_Instruction{kind = .F64_Const, f64_val = folded})
					i += 3
					changed = true
					continue
				}
			}

			// f32 constant folding
			if a.kind == .F32_Const && b.kind == .F32_Const {
				folded: f32
				did_fold := true
				#partial switch op.kind {
				case .F32_Add: folded = a.f32_val + b.f32_val
				case .F32_Sub: folded = a.f32_val - b.f32_val
				case .F32_Mul: folded = a.f32_val * b.f32_val
				case .F32_Div:
					if b.f32_val != 0 { folded = a.f32_val / b.f32_val } else { did_fold = false }
				case:
					did_fold = false
				}
				if did_fold {
					append(&out, WASM_Instruction{kind = .F32_Const, f32_val = folded})
					i += 3
					changed = true
					continue
				}
			}
		}

		// Single-instruction folding: i32.const + i32.eqz → i32.const
		if i + 1 < len(body^) {
			a := body[i]
			op := body[i + 1]
			if a.kind == .I32_Const && op.kind == .I32_Eqz {
				append(&out, WASM_Instruction{kind = .I32_Const, i32_val = 1 if a.i32_val == 0 else 0})
				i += 2
				changed = true
				continue
			}
		}

		append(&out, body[i])
		i += 1
	}

	if changed {
		clear(body)
		for instr in out { append(body, instr) }
	}
	return changed
}

// === Pass 2: Dead Code Elimination ===
// Remove instructions after return/br/unreachable until next end/else.

dead_code_eliminate :: proc(body: ^[dynamic]WASM_Instruction, allocator: mem.Allocator) -> bool {
	changed := false
	out := make([dynamic]WASM_Instruction, 0, len(body^), allocator)
	dead := false

	for &instr in body^ {
		// Terminators start dead code region
		if !dead && (instr.kind == .Return || instr.kind == .Unreachable) {
			append(&out, instr)
			dead = true
			continue
		}
		// Unconditional branch also starts dead region
		if !dead && instr.kind == .Br {
			append(&out, instr)
			dead = true
			continue
		}
		// end/else/block/loop/if resume live code
		if dead && (instr.kind == .End || instr.kind == .Else || instr.kind == .Block || instr.kind == .Loop || instr.kind == .If) {
			dead = false
			append(&out, instr)
			continue
		}
		if dead {
			changed = true
			continue
		}
		append(&out, instr)
	}

	if changed {
		clear(body)
		for instr in out { append(body, instr) }
	}
	return changed
}

// === Pass 3: Peephole Optimizations ===

peephole_optimize :: proc(body: ^[dynamic]WASM_Instruction, allocator: mem.Allocator) -> bool {
	changed := false
	out := make([dynamic]WASM_Instruction, 0, len(body^), allocator)
	i := 0

	for i < len(body^) {
		// local.set X; local.get X → local.tee X
		if i + 1 < len(body^) {
			a := body[i]
			b := body[i + 1]
			if a.kind == .Local_Set && b.kind == .Local_Get && a.local_idx == b.local_idx {
				append(&out, WASM_Instruction{kind = .Local_Tee, local_idx = a.local_idx})
				i += 2
				changed = true
				continue
			}
		}

		// i32.eqz; i32.eqz → remove both (double negation)
		if i + 1 < len(body^) {
			a := body[i]
			b := body[i + 1]
			if a.kind == .I32_Eqz && b.kind == .I32_Eqz {
				// Only if result is used as boolean (0 or 1).
				// For general values, we'd need i32.eqz; i32.eqz to normalize.
				// Skip this optimization to be safe — keep both.
				// Actually, eqz(eqz(x)) = (x == 0) == 0 = x != 0, which isn't identity.
				// Only remove if followed by br_if (truthiness check).
				if i + 2 < len(body^) && body[i + 2].kind == .Br_If {
					// eqz; eqz; br_if → br_if (same truthiness)
					i += 2
					changed = true
					continue
				}
			}
		}

		// Nop removal
		if body[i].kind == .Nop {
			i += 1
			changed = true
			continue
		}

		append(&out, body[i])
		i += 1
	}

	if changed {
		clear(body)
		for instr in out { append(body, instr) }
	}
	return changed
}
