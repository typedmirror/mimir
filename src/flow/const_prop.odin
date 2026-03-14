package flow

import "core:mem"
import parser "mimir:parser"
import binder "mimir:binder"

// ==================== Constant Value Lattice ====================

Const_Value :: union {
	Const_Int,
	Const_Float,
	Const_Str,
	Const_Bool,
	Const_None,
	Const_Tuple,
	Const_Bottom,
}

Const_Int    :: struct { value: i64 }
Const_Float  :: struct { value: f64 }
Const_Str    :: struct { value: string }
Const_Bool   :: struct { value: bool }
Const_None   :: struct {}
Const_Tuple  :: struct { elements: []Const_Value }
Const_Bottom :: struct {} // Overdefined — different values reach this point

Const_Map :: map[binder.Symbol_ID]Const_Value

// ==================== Constant Propagation ====================

propagate_constants :: proc(
	dfg: ^DFG,
	cfg: ^CFG,
	bind_result: ^binder.Bind_Result,
	module: ^parser.Module,  // reserved for future inter-procedural const prop
	allocator: mem.Allocator,
) -> Const_Map {
	result := make(Const_Map, 16, allocator)

	// For each definition point, try to extract a constant value from RHS
	for &def in dfg.defs {
		if def.stmt_idx < 0 { continue } // Parameter defs have stmt_idx = -1

		block_idx := int(def.block_id) - 1
		if block_idx < 0 || block_idx >= len(cfg.blocks) { continue }

		block := &cfg.blocks[block_idx]
		if def.stmt_idx >= len(block.stmts) { continue }

		stmt := block.stmts[def.stmt_idx]
		rhs := get_stmt_rhs(stmt, def.symbol_id, bind_result)
		if rhs == nil { continue }

		cv := eval_const_expr(rhs, &result, bind_result, allocator)
		if cv == nil { continue }

		// Merge with existing value for this symbol
		if existing, ok := result[def.symbol_id]; ok {
			// If same constant, keep it; if different, Bottom
			if !const_values_equal(existing, cv) {
				result[def.symbol_id] = Const_Bottom{}
			}
		} else {
			result[def.symbol_id] = cv
		}
	}

	return result
}

// ==================== RHS Extraction ====================

get_stmt_rhs :: proc(stmt: parser.Stmt, target_sym: binder.Symbol_ID, bind_result: ^binder.Bind_Result) -> parser.Expr {
	#partial switch s in stmt {
	case ^parser.Assign:
		// Only single-target assignments produce reliable constants
		if len(s.targets) == 1 {
			if name, ok := s.targets[0].(^parser.Name_Expr); ok {
				sym_id, ref_ok := binder.get_ref(bind_result, rawptr(name))
				if ref_ok && sym_id == target_sym {
					return s.value
				}
			}
		}
	case ^parser.Ann_Assign:
		if s.value != nil {
			if name, ok := s.target.(^parser.Name_Expr); ok {
				sym_id, ref_ok := binder.get_ref(bind_result, rawptr(name))
				if ref_ok && sym_id == target_sym {
					return s.value
				}
			}
		}
	}
	return nil
}

// ==================== Constant Expression Evaluation ====================

eval_const_expr :: proc(expr: parser.Expr, known: ^Const_Map, bind_result: ^binder.Bind_Result, allocator: mem.Allocator) -> Const_Value {
	if expr == nil { return nil }

	#partial switch e in expr {
	case ^parser.Constant_Expr:
		return eval_constant(e)

	case ^parser.Unary_Op_Expr:
		operand := eval_const_expr(e.operand, known, bind_result, allocator)
		if operand == nil { return nil }
		return eval_unary(e.op, operand)

	case ^parser.Name_Expr:
		// Propagate through known constants
		sym_id, ok := binder.get_ref(bind_result, rawptr(e))
		if !ok { return nil }
		if val, found := known[sym_id]; found {
			// Don't propagate Bottom
			_, is_bottom := val.(Const_Bottom)
			if !is_bottom { return val }
		}
		return nil

	case ^parser.Tuple_Expr:
		elements := make([]Const_Value, len(e.elts), allocator)
		for elt, i in e.elts {
			cv := eval_const_expr(elt, known, bind_result, allocator)
			if cv == nil { return nil }
			elements[i] = cv
		}
		return Const_Tuple{elements = elements}
	}

	return nil
}

eval_constant :: proc(c: ^parser.Constant_Expr) -> Const_Value {
	switch v in c.value {
	case i64:
		return Const_Int{value = v}
	case f64:
		return Const_Float{value = v}
	case string:
		return Const_Str{value = v}
	case bool:
		return Const_Bool{value = v}
	case parser.Const_None:
		return Const_None{}
	case parser.Const_Bytes:
		return nil
	case parser.Const_Ellipsis:
		return nil
	case parser.Const_Complex:
		return nil
	}
	return nil
}

eval_unary :: proc(op: parser.Unary_Op, operand: Const_Value) -> Const_Value {
	switch op {
	case .USub:
		#partial switch v in operand {
		case Const_Int:   return Const_Int{value = -v.value}
		case Const_Float: return Const_Float{value = -v.value}
		}
	case .UAdd:
		#partial switch v in operand {
		case Const_Int:   return v
		case Const_Float: return v
		}
	case .Not:
		#partial switch v in operand {
		case Const_Bool: return Const_Bool{value = !v.value}
		}
	case .Invert:
		#partial switch v in operand {
		case Const_Int: return Const_Int{value = ~v.value}
		}
	}
	return nil
}

// ==================== Equality ====================

const_values_equal :: proc(a, b: Const_Value) -> bool {
	switch va in a {
	case Const_Int:
		if vb, ok := b.(Const_Int); ok { return va.value == vb.value }
	case Const_Float:
		if vb, ok := b.(Const_Float); ok { return va.value == vb.value }
	case Const_Str:
		if vb, ok := b.(Const_Str); ok { return va.value == vb.value }
	case Const_Bool:
		if vb, ok := b.(Const_Bool); ok { return va.value == vb.value }
	case Const_None:
		_, ok := b.(Const_None)
		return ok
	case Const_Tuple:
		if vb, ok := b.(Const_Tuple); ok {
			if len(va.elements) != len(vb.elements) { return false }
			for i in 0..<len(va.elements) {
				if !const_values_equal(va.elements[i], vb.elements[i]) { return false }
			}
			return true
		}
	case Const_Bottom:
		return false // Bottom never equals anything
	case nil:
		return b == nil
	}
	return false
}
