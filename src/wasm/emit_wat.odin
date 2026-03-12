package wasm

import "core:mem"
import "core:fmt"
import "core:strings"

// WAT (WebAssembly Text format) emission — S-expression output.

emit_wat :: proc(module: ^WASM_Module, allocator: mem.Allocator) -> string {
	b := strings.builder_make(0, 4096, allocator)

	fmt.sbprint(&b, "(module\n")

	// Memory export
	fmt.sbprintf(&b, "  (memory (export \"memory\") %d)\n", module.memory_pages)

	// Functions
	for &func in module.functions {
		emit_wat_function(&func, &b)
	}

	fmt.sbprint(&b, ")\n")
	return strings.to_string(b)
}

emit_wat_function :: proc(func: ^WASM_Function, sb: ^strings.Builder) {
	// Function header
	fmt.sbprintf(sb, "  (func $%s", func.name)
	if func.exported {
		fmt.sbprintf(sb, " (export \"%s\")", func.name)
	}
	fmt.sbprint(sb, "\n")

	// Parameters
	for param, idx in func.type.params {
		fmt.sbprintf(sb, "    (param $p%d %s)\n", idx, wasm_type_str(param))
	}

	// Results
	for result in func.type.results {
		fmt.sbprintf(sb, "    (result %s)\n", wasm_type_str(result))
	}

	// Locals (non-parameter)
	for local in func.locals {
		fmt.sbprintf(sb, "    (local $%s %s)\n", local.name, wasm_type_str(local.type))
	}

	// Instructions
	indent := 2
	for &instr in func.body {
		// Adjust indent for block endings
		if instr.kind == .End || instr.kind == .Else {
			indent -= 1
			if indent < 2 { indent = 2 }
		}

		emit_wat_instruction(&instr, sb, indent)

		// Increase indent after block openings
		if instr.kind == .Block || instr.kind == .Loop || instr.kind == .If || instr.kind == .Else {
			indent += 1
		}
	}

	fmt.sbprint(sb, "  )\n")
}

emit_wat_instruction :: proc(instr: ^WASM_Instruction, sb: ^strings.Builder, indent: int) {
	// Write indentation
	for _ in 0..<indent {
		fmt.sbprint(sb, "    ")
	}

	name := wat_instr_name(instr.kind)

	#partial switch instr.kind {
	// Constants
	case .I32_Const:
		fmt.sbprintf(sb, "%s %d\n", name, instr.i32_val)
	case .I64_Const:
		fmt.sbprintf(sb, "%s %d\n", name, instr.i64_val)
	case .F32_Const:
		fmt.sbprintf(sb, "%s %f\n", name, instr.f32_val)
	case .F64_Const:
		fmt.sbprintf(sb, "%s %f\n", name, instr.f64_val)

	// Local ops
	case .Local_Get, .Local_Set, .Local_Tee:
		fmt.sbprintf(sb, "%s %d\n", name, instr.local_idx)

	// Branch ops
	case .Br, .Br_If:
		fmt.sbprintf(sb, "%s %d\n", name, instr.label_idx)

	// Call
	case .Call:
		fmt.sbprintf(sb, "%s %d\n", name, instr.func_idx)

	// Block types
	case .Block, .Loop:
		if instr.block_type != .Void {
			fmt.sbprintf(sb, "%s (result %s)\n", name, wasm_type_str(instr.block_type))
		} else {
			fmt.sbprintf(sb, "%s\n", name)
		}
	case .If:
		if instr.block_type != .Void {
			fmt.sbprintf(sb, "%s (result %s)\n", name, wasm_type_str(instr.block_type))
		} else {
			fmt.sbprintf(sb, "%s\n", name)
		}

	// Memory ops
	case .I32_Load, .I32_Store, .I64_Load, .I64_Store,
	     .F32_Load, .F32_Store, .F64_Load, .F64_Store,
	     .I32_Load8_U, .I32_Store8:
		if instr.mem_offset > 0 {
			fmt.sbprintf(sb, "%s offset=%d\n", name, instr.mem_offset)
		} else {
			fmt.sbprintf(sb, "%s\n", name)
		}

	// Everything else
	case:
		fmt.sbprintf(sb, "%s\n", name)
	}
}

// Map instruction kind to WAT mnemonic.
wat_instr_name :: proc(kind: WASM_Instr_Kind) -> string {
	switch kind {
	case .I32_Const:  return "i32.const"
	case .I64_Const:  return "i64.const"
	case .F32_Const:  return "f32.const"
	case .F64_Const:  return "f64.const"
	case .Local_Get:  return "local.get"
	case .Local_Set:  return "local.set"
	case .Local_Tee:  return "local.tee"

	case .I32_Add:    return "i32.add"
	case .I32_Sub:    return "i32.sub"
	case .I32_Mul:    return "i32.mul"
	case .I32_Div_S:  return "i32.div_s"
	case .I32_Rem_S:  return "i32.rem_s"
	case .I32_And:    return "i32.and"
	case .I32_Or:     return "i32.or"
	case .I32_Xor:    return "i32.xor"
	case .I32_Shl:    return "i32.shl"
	case .I32_Shr_S:  return "i32.shr_s"

	case .I64_Add:    return "i64.add"
	case .I64_Sub:    return "i64.sub"
	case .I64_Mul:    return "i64.mul"
	case .I64_Div_S:  return "i64.div_s"
	case .I64_Rem_S:  return "i64.rem_s"

	case .F32_Add:    return "f32.add"
	case .F32_Sub:    return "f32.sub"
	case .F32_Mul:    return "f32.mul"
	case .F32_Div:    return "f32.div"
	case .F32_Abs:    return "f32.abs"
	case .F32_Neg:    return "f32.neg"
	case .F32_Sqrt:   return "f32.sqrt"
	case .F32_Min:    return "f32.min"
	case .F32_Max:    return "f32.max"
	case .F32_Floor:  return "f32.floor"
	case .F32_Ceil:   return "f32.ceil"
	case .F32_Trunc:  return "f32.trunc"
	case .F32_Nearest: return "f32.nearest"

	case .F64_Add:    return "f64.add"
	case .F64_Sub:    return "f64.sub"
	case .F64_Mul:    return "f64.mul"
	case .F64_Div:    return "f64.div"
	case .F64_Abs:    return "f64.abs"
	case .F64_Neg:    return "f64.neg"
	case .F64_Sqrt:   return "f64.sqrt"
	case .F64_Min:    return "f64.min"
	case .F64_Max:    return "f64.max"
	case .F64_Floor:  return "f64.floor"
	case .F64_Ceil:   return "f64.ceil"
	case .F64_Trunc:  return "f64.trunc"
	case .F64_Nearest: return "f64.nearest"

	case .I32_Eqz:    return "i32.eqz"
	case .I32_Eq:     return "i32.eq"
	case .I32_Ne:     return "i32.ne"
	case .I32_Lt_S:   return "i32.lt_s"
	case .I32_Gt_S:   return "i32.gt_s"
	case .I32_Le_S:   return "i32.le_s"
	case .I32_Ge_S:   return "i32.ge_s"

	case .I64_Eqz:    return "i64.eqz"
	case .I64_Eq:     return "i64.eq"
	case .I64_Ne:     return "i64.ne"
	case .I64_Lt_S:   return "i64.lt_s"
	case .I64_Gt_S:   return "i64.gt_s"
	case .I64_Le_S:   return "i64.le_s"
	case .I64_Ge_S:   return "i64.ge_s"

	case .F32_Eq:     return "f32.eq"
	case .F32_Ne:     return "f32.ne"
	case .F32_Lt:     return "f32.lt"
	case .F32_Gt:     return "f32.gt"
	case .F32_Le:     return "f32.le"
	case .F32_Ge:     return "f32.ge"

	case .F64_Eq:     return "f64.eq"
	case .F64_Ne:     return "f64.ne"
	case .F64_Lt:     return "f64.lt"
	case .F64_Gt:     return "f64.gt"
	case .F64_Le:     return "f64.le"
	case .F64_Ge:     return "f64.ge"

	case .I32_Wrap_I64:       return "i32.wrap_i64"
	case .I64_Extend_I32_S:   return "i64.extend_i32_s"
	case .F32_Convert_I32_S:  return "f32.convert_i32_s"
	case .F64_Convert_I32_S:  return "f64.convert_i32_s"
	case .F32_Convert_I64_S:  return "f32.convert_i64_s"
	case .F64_Convert_I64_S:  return "f64.convert_i64_s"
	case .I32_Trunc_F32_S:    return "i32.trunc_f32_s"
	case .I32_Trunc_F64_S:    return "i32.trunc_f64_s"
	case .F32_Demote_F64:     return "f32.demote_f64"
	case .F64_Promote_F32:    return "f64.promote_f32"

	case .I32_Load:    return "i32.load"
	case .I32_Store:   return "i32.store"
	case .I64_Load:    return "i64.load"
	case .I64_Store:   return "i64.store"
	case .F32_Load:    return "f32.load"
	case .F32_Store:   return "f32.store"
	case .F64_Load:    return "f64.load"
	case .F64_Store:   return "f64.store"
	case .I32_Load8_U: return "i32.load8_u"
	case .I32_Store8:  return "i32.store8"
	case .Memory_Size: return "memory.size"
	case .Memory_Grow: return "memory.grow"

	case .Block:       return "block"
	case .Loop:        return "loop"
	case .If:          return "if"
	case .Else:        return "else"
	case .End:         return "end"
	case .Br:          return "br"
	case .Br_If:       return "br_if"
	case .Return:      return "return"

	case .Call:        return "call"
	case .Drop:        return "drop"
	case .Select:      return "select"
	case .Nop:         return "nop"
	case .Unreachable: return "unreachable"
	}
	return "nop"
}
