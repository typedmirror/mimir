package wasm

import "core:mem"
import "core:math"

// WASM Binary format emission — WebAssembly 1.0 MVP spec.
// Produces valid .wasm files loadable by WebAssembly.instantiate().

WASM_MAGIC   :: [4]u8{0x00, 0x61, 0x73, 0x6D}  // "\0asm"
WASM_VERSION :: [4]u8{0x01, 0x00, 0x00, 0x00}

// Section IDs
SECTION_TYPE     :: 1
SECTION_FUNCTION :: 3
SECTION_MEMORY   :: 5
SECTION_EXPORT   :: 7
SECTION_CODE     :: 10

// Value type encodings
VALTYPE_I32 :: 0x7F
VALTYPE_I64 :: 0x7E
VALTYPE_F32 :: 0x7D
VALTYPE_F64 :: 0x7C

// Block types
BLOCKTYPE_VOID :: 0x40
BLOCKTYPE_I32  :: 0x7F
BLOCKTYPE_I64  :: 0x7E
BLOCKTYPE_F32  :: 0x7D
BLOCKTYPE_F64  :: 0x7C

// Export kinds
EXPORT_FUNC   :: 0x00
EXPORT_MEMORY :: 0x02

emit_wasm_binary :: proc(module: ^WASM_Module, allocator: mem.Allocator) -> []u8 {
	buf := make([dynamic]u8, 0, 4096, allocator)

	// Magic + version
	for b in WASM_MAGIC   { append(&buf, b) }
	for b in WASM_VERSION { append(&buf, b) }

	// Section 1: Type section — function signatures
	emit_type_section(module, &buf, allocator)

	// Section 3: Function section — type indices
	emit_function_section(module, &buf, allocator)

	// Section 5: Memory section
	emit_memory_section(module, &buf, allocator)

	// Section 7: Export section
	emit_export_section(module, &buf, allocator)

	// Section 10: Code section — function bodies
	emit_code_section(module, &buf, allocator)

	return buf[:]
}

// === LEB128 encoding ===

encode_uleb128 :: proc(buf: ^[dynamic]u8, value: u64) {
	v := value
	for {
		b := u8(v & 0x7F)
		v >>= 7
		if v != 0 { b |= 0x80 }
		append(buf, b)
		if v == 0 { break }
	}
}

encode_sleb128 :: proc(buf: ^[dynamic]u8, value: i64) {
	v := value
	for {
		b := u8(v & 0x7F)
		v >>= 7
		more := !((v == 0 && (b & 0x40) == 0) || (v == -1 && (b & 0x40) != 0))
		if more { b |= 0x80 }
		append(buf, b)
		if !more { break }
	}
}

// === Section emission ===

emit_type_section :: proc(module: ^WASM_Module, buf: ^[dynamic]u8, allocator: mem.Allocator) {
	if len(module.functions) == 0 { return }

	section_buf := make([dynamic]u8, 0, 256, allocator)

	// Number of types
	encode_uleb128(&section_buf, u64(len(module.functions)))

	for &func in module.functions {
		append(&section_buf, 0x60) // functype prefix

		// Params
		encode_uleb128(&section_buf, u64(len(func.type.params)))
		for p in func.type.params {
			append(&section_buf, valtype_byte(p))
		}

		// Results
		encode_uleb128(&section_buf, u64(len(func.type.results)))
		for r in func.type.results {
			append(&section_buf, valtype_byte(r))
		}
	}

	// Write section header
	append(buf, SECTION_TYPE)
	encode_uleb128(buf, u64(len(section_buf)))
	for b in section_buf { append(buf, b) }
}

emit_function_section :: proc(module: ^WASM_Module, buf: ^[dynamic]u8, allocator: mem.Allocator) {
	if len(module.functions) == 0 { return }

	section_buf := make([dynamic]u8, 0, 64, allocator)
	encode_uleb128(&section_buf, u64(len(module.functions)))
	for i in 0..<len(module.functions) {
		encode_uleb128(&section_buf, u64(i)) // type index = function index (1:1)
	}

	append(buf, SECTION_FUNCTION)
	encode_uleb128(buf, u64(len(section_buf)))
	for b in section_buf { append(buf, b) }
}

emit_memory_section :: proc(module: ^WASM_Module, buf: ^[dynamic]u8, allocator: mem.Allocator) {
	section_buf := make([dynamic]u8, 0, 16, allocator)
	encode_uleb128(&section_buf, 1) // 1 memory
	append(&section_buf, 0x00)      // limits: min only
	encode_uleb128(&section_buf, u64(module.memory_pages))

	append(buf, SECTION_MEMORY)
	encode_uleb128(buf, u64(len(section_buf)))
	for b in section_buf { append(buf, b) }
}

emit_export_section :: proc(module: ^WASM_Module, buf: ^[dynamic]u8, allocator: mem.Allocator) {
	section_buf := make([dynamic]u8, 0, 256, allocator)

	// Count exports: exported functions + memory
	export_count := 1 // memory always exported
	for &func in module.functions {
		if func.exported { export_count += 1 }
	}
	encode_uleb128(&section_buf, u64(export_count))

	// Export memory
	emit_export_entry(&section_buf, "memory", EXPORT_MEMORY, 0)

	// Export functions
	func_idx := 0
	for &func in module.functions {
		if func.exported {
			emit_export_entry(&section_buf, func.name, EXPORT_FUNC, func_idx)
		}
		func_idx += 1
	}

	append(buf, SECTION_EXPORT)
	encode_uleb128(buf, u64(len(section_buf)))
	for b in section_buf { append(buf, b) }
}

emit_export_entry :: proc(buf: ^[dynamic]u8, name: string, kind: u8, idx: int) {
	// Name length + name bytes
	name_bytes := transmute([]u8)name
	encode_uleb128(buf, u64(len(name_bytes)))
	for b in name_bytes { append(buf, b) }
	append(buf, kind)
	encode_uleb128(buf, u64(idx))
}

emit_code_section :: proc(module: ^WASM_Module, buf: ^[dynamic]u8, allocator: mem.Allocator) {
	if len(module.functions) == 0 { return }

	section_buf := make([dynamic]u8, 0, 1024, allocator)
	encode_uleb128(&section_buf, u64(len(module.functions)))

	for &func in module.functions {
		emit_function_body(&func, &section_buf, allocator)
	}

	append(buf, SECTION_CODE)
	encode_uleb128(buf, u64(len(section_buf)))
	for b in section_buf { append(buf, b) }
}

emit_function_body :: proc(func: ^WASM_Function, buf: ^[dynamic]u8, allocator: mem.Allocator) {
	body_buf := make([dynamic]u8, 0, 256, allocator)

	// Local declarations: group consecutive same-type locals
	if len(func.locals) == 0 {
		encode_uleb128(&body_buf, 0)
	} else {
		// Compress locals: count runs of same type
		groups := make([dynamic][2]int, 0, len(func.locals), allocator) // [count, type_byte]
		i := 0
		for i < len(func.locals) {
			t := func.locals[i].type
			count := 1
			for i + count < len(func.locals) && func.locals[i + count].type == t {
				count += 1
			}
			append(&groups, [2]int{count, int(valtype_byte(t))})
			i += count
		}
		encode_uleb128(&body_buf, u64(len(groups)))
		for g in groups {
			encode_uleb128(&body_buf, u64(g[0]))
			append(&body_buf, u8(g[1]))
		}
	}

	// Instructions
	for &instr in func.body {
		emit_binary_instruction(&instr, &body_buf)
	}

	// Implicit end
	append(&body_buf, 0x0B)

	// Write body size + body
	encode_uleb128(buf, u64(len(body_buf)))
	for b in body_buf { append(buf, b) }
}

emit_binary_instruction :: proc(instr: ^WASM_Instruction, buf: ^[dynamic]u8) {
	opcode := wasm_opcode(instr.kind)
	append(buf, opcode)

	#partial switch instr.kind {
	// Constants with immediate values
	case .I32_Const:
		encode_sleb128(buf, i64(instr.i32_val))
	case .I64_Const:
		encode_sleb128(buf, instr.i64_val)
	case .F32_Const:
		bits := transmute(u32)instr.f32_val
		append(buf, u8(bits))
		append(buf, u8(bits >> 8))
		append(buf, u8(bits >> 16))
		append(buf, u8(bits >> 24))
	case .F64_Const:
		bits := transmute(u64)instr.f64_val
		append(buf, u8(bits))
		append(buf, u8(bits >> 8))
		append(buf, u8(bits >> 16))
		append(buf, u8(bits >> 24))
		append(buf, u8(bits >> 32))
		append(buf, u8(bits >> 40))
		append(buf, u8(bits >> 48))
		append(buf, u8(bits >> 56))

	// Local variable ops
	case .Local_Get, .Local_Set, .Local_Tee:
		encode_uleb128(buf, u64(instr.local_idx))

	// Branch ops
	case .Br, .Br_If:
		encode_uleb128(buf, u64(instr.label_idx))

	// Call
	case .Call:
		encode_uleb128(buf, u64(instr.func_idx))

	// Block types
	case .Block, .Loop:
		append(buf, blocktype_byte(instr.block_type))
	case .If:
		append(buf, blocktype_byte(instr.block_type))

	// Memory ops: alignment + offset
	case .I32_Load, .I64_Load, .F32_Load, .F64_Load,
	     .I32_Store, .I64_Store, .F32_Store, .F64_Store:
		encode_uleb128(buf, u64(2)) // natural alignment
		encode_uleb128(buf, u64(instr.mem_offset))
	case .I32_Load8_U, .I32_Store8:
		encode_uleb128(buf, 0) // byte alignment
		encode_uleb128(buf, u64(instr.mem_offset))

	// Memory size/grow: memory index 0
	case .Memory_Size, .Memory_Grow:
		append(buf, 0x00)

	// Everything else: no immediates
	case:
		// no additional bytes
	}
}

// === Opcode mapping ===

wasm_opcode :: proc(kind: WASM_Instr_Kind) -> u8 {
	switch kind {
	case .Unreachable: return 0x00
	case .Nop:         return 0x01
	case .Block:       return 0x02
	case .Loop:        return 0x03
	case .If:          return 0x04
	case .Else:        return 0x05
	case .End:         return 0x0B
	case .Br:          return 0x0C
	case .Br_If:       return 0x0D
	case .Return:      return 0x0F
	case .Call:        return 0x10
	case .Drop:        return 0x1A
	case .Select:      return 0x1B
	case .Local_Get:   return 0x20
	case .Local_Set:   return 0x21
	case .Local_Tee:   return 0x22

	case .I32_Load:    return 0x28
	case .I64_Load:    return 0x29
	case .F32_Load:    return 0x2A
	case .F64_Load:    return 0x2B
	case .I32_Load8_U: return 0x2D
	case .I32_Store:   return 0x36
	case .I64_Store:   return 0x37
	case .F32_Store:   return 0x38
	case .F64_Store:   return 0x39
	case .I32_Store8:  return 0x3A
	case .Memory_Size: return 0x3F
	case .Memory_Grow: return 0x40

	case .I32_Const:   return 0x41
	case .I64_Const:   return 0x42
	case .F32_Const:   return 0x43
	case .F64_Const:   return 0x44

	case .I32_Eqz:     return 0x45
	case .I32_Eq:      return 0x46
	case .I32_Ne:      return 0x47
	case .I32_Lt_S:    return 0x48
	case .I32_Gt_S:    return 0x4A
	case .I32_Le_S:    return 0x4C
	case .I32_Ge_S:    return 0x4E

	case .I64_Eqz:     return 0x50
	case .I64_Eq:      return 0x51
	case .I64_Ne:      return 0x52
	case .I64_Lt_S:    return 0x53
	case .I64_Gt_S:    return 0x55
	case .I64_Le_S:    return 0x57
	case .I64_Ge_S:    return 0x59

	case .F32_Eq:      return 0x5B
	case .F32_Ne:      return 0x5C
	case .F32_Lt:      return 0x5D
	case .F32_Gt:      return 0x5E
	case .F32_Le:      return 0x5F
	case .F32_Ge:      return 0x60

	case .F64_Eq:      return 0x61
	case .F64_Ne:      return 0x62
	case .F64_Lt:      return 0x63
	case .F64_Gt:      return 0x64
	case .F64_Le:      return 0x65
	case .F64_Ge:      return 0x66

	case .I32_Add:     return 0x6A
	case .I32_Sub:     return 0x6B
	case .I32_Mul:     return 0x6C
	case .I32_Div_S:   return 0x6D
	case .I32_Rem_S:   return 0x6F
	case .I32_And:     return 0x71
	case .I32_Or:      return 0x72
	case .I32_Xor:     return 0x73
	case .I32_Shl:     return 0x74
	case .I32_Shr_S:   return 0x75

	case .I64_Add:     return 0x7C
	case .I64_Sub:     return 0x7D
	case .I64_Mul:     return 0x7E
	case .I64_Div_S:   return 0x7F
	case .I64_Rem_S:   return 0x81

	case .F32_Abs:     return 0x8B
	case .F32_Neg:     return 0x8C
	case .F32_Ceil:    return 0x8D
	case .F32_Floor:   return 0x8E
	case .F32_Trunc:   return 0x8F
	case .F32_Nearest: return 0x90
	case .F32_Sqrt:    return 0x91
	case .F32_Add:     return 0x92
	case .F32_Sub:     return 0x93
	case .F32_Mul:     return 0x94
	case .F32_Div:     return 0x95
	case .F32_Min:     return 0x96
	case .F32_Max:     return 0x97

	case .F64_Abs:     return 0x99
	case .F64_Neg:     return 0x9A
	case .F64_Ceil:    return 0x9B
	case .F64_Floor:   return 0x9C
	case .F64_Trunc:   return 0x9D
	case .F64_Nearest: return 0x9E
	case .F64_Sqrt:    return 0x9F
	case .F64_Add:     return 0xA0
	case .F64_Sub:     return 0xA1
	case .F64_Mul:     return 0xA2
	case .F64_Div:     return 0xA3
	case .F64_Min:     return 0xA4
	case .F64_Max:     return 0xA5

	case .I32_Wrap_I64:      return 0xA7
	case .I32_Trunc_F32_S:   return 0xA8
	case .I32_Trunc_F64_S:   return 0xAA
	case .I64_Extend_I32_S:  return 0xAC
	case .F32_Convert_I32_S: return 0xB2
	case .F32_Convert_I64_S: return 0xB4
	case .F32_Demote_F64:    return 0xB6
	case .F64_Convert_I32_S: return 0xB7
	case .F64_Convert_I64_S: return 0xB9
	case .F64_Promote_F32:   return 0xBB
	}
	return 0x01 // nop
}

// === Helpers ===

valtype_byte :: proc(t: WASM_Value_Type) -> u8 {
	switch t {
	case .I32:  return VALTYPE_I32
	case .I64:  return VALTYPE_I64
	case .F32:  return VALTYPE_F32
	case .F64:  return VALTYPE_F64
	case .Void: return VALTYPE_I32
	}
	return VALTYPE_I32
}

blocktype_byte :: proc(t: WASM_Value_Type) -> u8 {
	switch t {
	case .Void: return BLOCKTYPE_VOID
	case .I32:  return BLOCKTYPE_I32
	case .I64:  return BLOCKTYPE_I64
	case .F32:  return BLOCKTYPE_F32
	case .F64:  return BLOCKTYPE_F64
	}
	return BLOCKTYPE_VOID
}
