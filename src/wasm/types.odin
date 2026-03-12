package wasm

import "core:mem"
import "core:fmt"

import parser "mimir:parser"

// WASM value types — maps to WebAssembly 1.0 MVP types.
WASM_Value_Type :: enum {
	I32,
	I64,
	F32,
	F64,
	Void,
}

// WASM function signature.
WASM_Func_Type :: struct {
	params:  []WASM_Value_Type,
	results: []WASM_Value_Type,
}

// Non-parameter local variable.
WASM_Local :: struct {
	name: string,
	type: WASM_Value_Type,
}

// Stack-based instruction kinds (~80 variants).
WASM_Instr_Kind :: enum {
	// Constants
	I32_Const, I64_Const, F32_Const, F64_Const,
	// Local variable ops
	Local_Get, Local_Set, Local_Tee,
	// i32 arithmetic
	I32_Add, I32_Sub, I32_Mul, I32_Div_S, I32_Rem_S,
	I32_And, I32_Or, I32_Xor, I32_Shl, I32_Shr_S,
	// i64 arithmetic
	I64_Add, I64_Sub, I64_Mul, I64_Div_S, I64_Rem_S,
	// f32 arithmetic
	F32_Add, F32_Sub, F32_Mul, F32_Div,
	F32_Abs, F32_Neg, F32_Sqrt, F32_Min, F32_Max,
	F32_Floor, F32_Ceil, F32_Trunc, F32_Nearest,
	// f64 arithmetic
	F64_Add, F64_Sub, F64_Mul, F64_Div,
	F64_Abs, F64_Neg, F64_Sqrt, F64_Min, F64_Max,
	F64_Floor, F64_Ceil, F64_Trunc, F64_Nearest,
	// i32 comparison
	I32_Eqz, I32_Eq, I32_Ne, I32_Lt_S, I32_Gt_S, I32_Le_S, I32_Ge_S,
	// i64 comparison
	I64_Eqz, I64_Eq, I64_Ne, I64_Lt_S, I64_Gt_S, I64_Le_S, I64_Ge_S,
	// f32 comparison
	F32_Eq, F32_Ne, F32_Lt, F32_Gt, F32_Le, F32_Ge,
	// f64 comparison
	F64_Eq, F64_Ne, F64_Lt, F64_Gt, F64_Le, F64_Ge,
	// Conversions
	I32_Wrap_I64, I64_Extend_I32_S,
	F32_Convert_I32_S, F64_Convert_I32_S,
	F32_Convert_I64_S, F64_Convert_I64_S,
	I32_Trunc_F32_S, I32_Trunc_F64_S,
	F32_Demote_F64, F64_Promote_F32,
	// Memory
	I32_Load, I32_Store, I64_Load, I64_Store,
	F32_Load, F32_Store, F64_Load, F64_Store,
	I32_Load8_U, I32_Store8,
	Memory_Size, Memory_Grow,
	// Control flow
	Block, Loop, If, Else, End,
	Br, Br_If, Return,
	// Function calls
	Call,
	// Stack ops
	Drop, Select, Nop, Unreachable,
}

// Single WASM instruction with operand fields.
WASM_Instruction :: struct {
	kind:       WASM_Instr_Kind,
	i32_val:    i32,
	i64_val:    i64,
	f32_val:    f32,
	f64_val:    f64,
	local_idx:  int,
	label_idx:  int,
	func_idx:   int,
	block_type: WASM_Value_Type,
	mem_align:  int,
	mem_offset: int,
}

// A compiled WASM function.
WASM_Function :: struct {
	name:     string,
	type:     WASM_Func_Type,
	locals:   [dynamic]WASM_Local,
	body:     [dynamic]WASM_Instruction,
	exported: bool,
}

// A WASM module containing functions and memory.
WASM_Module :: struct {
	functions:    [dynamic]WASM_Function,
	memory_pages: int,
	allocator:    mem.Allocator,
}

// Type resolution context for Python → WASM type mapping.
WASM_Type_Context :: struct {
	wasm_names: map[string]WASM_Value_Type,
	allocator:  mem.Allocator,
}

init_wasm_types :: proc(allocator: mem.Allocator) -> WASM_Type_Context {
	ctx: WASM_Type_Context
	ctx.allocator = allocator
	ctx.wasm_names = make(map[string]WASM_Value_Type, 16, allocator)

	// Python type name → WASM type
	ctx.wasm_names["int"]     = .I32
	ctx.wasm_names["float"]   = .F64
	ctx.wasm_names["bool"]    = .I32
	ctx.wasm_names["float32"] = .F32
	ctx.wasm_names["float64"] = .F64
	ctx.wasm_names["int32"]   = .I32
	ctx.wasm_names["int64"]   = .I64

	return ctx
}

// Resolve a Python type annotation to a WASM value type.
python_type_to_wasm :: proc(annotation: parser.Expr, ctx: ^WASM_Type_Context) -> WASM_Value_Type {
	if annotation == nil { return .Void }

	#partial switch e in annotation {
	case ^parser.Name_Expr:
		if wt, ok := ctx.wasm_names[e.id]; ok {
			return wt
		}
	case ^parser.Subscript_Expr:
		// Tensor[float32, ...] → I32 (pointer in linear memory)
		#partial switch v in e.value {
		case ^parser.Name_Expr:
			if v.id == "Tensor" { return .I32 }
		}
	}
	return .Void
}

// Check if a type annotation refers to a memory type (bytes or Tensor).
is_memory_type :: proc(annotation: parser.Expr) -> bool {
	if annotation == nil { return false }

	#partial switch e in annotation {
	case ^parser.Name_Expr:
		return e.id == "bytes"
	case ^parser.Subscript_Expr:
		#partial switch v in e.value {
		case ^parser.Name_Expr:
			return v.id == "Tensor"
		}
	}
	return false
}

// WASM type to string for WAT output.
wasm_type_str :: proc(type: WASM_Value_Type) -> string {
	switch type {
	case .I32:  return "i32"
	case .I64:  return "i64"
	case .F32:  return "f32"
	case .F64:  return "f64"
	case .Void: return ""
	}
	return ""
}

// Get the element byte size for a memory type annotation.
// bytes → 1, Tensor[float32] → 4, Tensor[float64] → 8.
memory_element_size :: proc(annotation: parser.Expr, ctx: ^WASM_Type_Context) -> int {
	#partial switch e in annotation {
	case ^parser.Name_Expr:
		if e.id == "bytes" { return 1 }
	case ^parser.Subscript_Expr:
		#partial switch v in e.value {
		case ^parser.Name_Expr:
			if v.id != "Tensor" { return 4 }
		}
		// Get dtype from subscript
		#partial switch s in e.slice {
		case ^parser.Tuple_Expr:
			if len(s.elts) >= 1 {
				#partial switch dt in s.elts[0] {
				case ^parser.Name_Expr:
					switch dt.id {
					case "float32": return 4
					case "float64": return 8
					case "int32":   return 4
					case "int64":   return 8
					}
				}
			}
		case ^parser.Name_Expr:
			switch s.id {
			case "float32": return 4
			case "float64": return 8
			case "int32":   return 4
			case "int64":   return 8
			}
		}
	}
	return 4 // default
}

// Get WASM load instruction for a memory type.
memory_load_kind :: proc(annotation: parser.Expr, ctx: ^WASM_Type_Context) -> WASM_Instr_Kind {
	#partial switch e in annotation {
	case ^parser.Name_Expr:
		if e.id == "bytes" { return .I32_Load8_U }
	case ^parser.Subscript_Expr:
		elem_size := memory_element_size(annotation, ctx)
		switch elem_size {
		case 4: return .F32_Load  // default Tensor → float32
		case 8: return .F64_Load
		}
		// Check dtype for int tensors
		dtype := tensor_dtype_name(e)
		if dtype == "int32" { return .I32_Load }
		if dtype == "int64" { return .I64_Load }
		if dtype == "float64" { return .F64_Load }
		return .F32_Load
	}
	return .I32_Load
}

// Helper: extract dtype name from Tensor subscript.
tensor_dtype_name :: proc(sub: ^parser.Subscript_Expr) -> string {
	#partial switch s in sub.slice {
	case ^parser.Tuple_Expr:
		if len(s.elts) >= 1 {
			#partial switch dt in s.elts[0] {
			case ^parser.Name_Expr:
				return dt.id
			}
		}
	case ^parser.Name_Expr:
		return s.id
	}
	return ""
}

// Get the WASM value type for a memory type's elements.
memory_elem_wasm_type :: proc(annotation: parser.Expr, ctx: ^WASM_Type_Context) -> WASM_Value_Type {
	#partial switch e in annotation {
	case ^parser.Name_Expr:
		if e.id == "bytes" { return .I32 }
	case ^parser.Subscript_Expr:
		dtype := tensor_dtype_name(e)
		if wt, ok := ctx.wasm_names[dtype]; ok {
			return wt
		}
		return .F32 // default Tensor → float32
	}
	return .I32
}
