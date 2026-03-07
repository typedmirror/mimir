package binder

import "core:mem"
import parser "mimir:parser"

Scope_ID :: distinct u32
INVALID_SCOPE :: Scope_ID(0)

Scope_Kind :: enum u8 {
	Builtin,
	Module,
	Class,
	Function,
	Lambda,
	Comprehension,
}

Scope :: struct {
	id:        Scope_ID,
	kind:      Scope_Kind,
	parent_id: Scope_ID,
	name:      string,
	loc:       parser.Src_Loc,
	symbols:   map[string]Symbol_ID,
}

push_scope :: proc(b: ^Binder, kind: Scope_Kind, name: string, loc: parser.Src_Loc) -> Scope_ID {
	parent := current_scope(b)

	b.next_scope_id += 1
	id := Scope_ID(b.next_scope_id)

	append(&b.result.scopes, Scope{
		id        = id,
		kind      = kind,
		parent_id = parent,
		name      = name,
		loc       = loc,
		symbols   = make(map[string]Symbol_ID, 16, b.allocator),
	})

	append(&b.scope_stack, id)
	return id
}

pop_scope :: proc(b: ^Binder) {
	if len(b.scope_stack) > 0 {
		pop(&b.scope_stack)
	}
}

current_scope :: proc(b: ^Binder) -> Scope_ID {
	if len(b.scope_stack) == 0 {
		return INVALID_SCOPE
	}
	return b.scope_stack[len(b.scope_stack) - 1]
}

get_scope :: proc(b: ^Binder, id: Scope_ID) -> ^Scope {
	idx := int(id) - 1
	if idx < 0 || idx >= len(b.result.scopes) {
		return nil
	}
	return &b.result.scopes[idx]
}

scope_lookup :: proc(b: ^Binder, scope_id: Scope_ID, name: string) -> (Symbol_ID, bool) {
	scope := get_scope(b, scope_id)
	if scope == nil {
		return INVALID_SYMBOL, false
	}
	if sym_id, ok := scope.symbols[name]; ok {
		return sym_id, true
	}
	return INVALID_SYMBOL, false
}

// LEGB resolution: walks scope chain, skipping class scopes (except the starting scope).
resolve_name :: proc(b: ^Binder, name: string, from_scope_id: Scope_ID) -> (Symbol_ID, bool) {
	current := from_scope_id
	first := true

	for current != INVALID_SCOPE {
		scope := get_scope(b, current)
		if scope == nil {
			break
		}

		if sym_id, ok := scope.symbols[name]; ok {
			sym := get_symbol(b, sym_id)
			if sym != nil {
				// If marked global, jump to module scope
				if .Is_Global in sym.flags {
					return resolve_in_module_scope(b, name)
				}
				// If marked nonlocal, skip and continue upward
				if .Is_Nonlocal in sym.flags {
					current = scope.parent_id
					first = false
					continue
				}
				return sym_id, true
			}
		}

		// Class scopes are skipped during LEGB (except when we start in one)
		if scope.kind == .Class && !first {
			current = scope.parent_id
			first = false
			continue
		}

		current = scope.parent_id
		first = false
	}

	return INVALID_SYMBOL, false
}

resolve_in_module_scope :: proc(b: ^Binder, name: string) -> (Symbol_ID, bool) {
	mod_scope := get_scope(b, b.result.module_scope)
	if mod_scope == nil {
		return INVALID_SYMBOL, false
	}
	if sym_id, ok := mod_scope.symbols[name]; ok {
		return sym_id, true
	}
	// Fall through to builtins
	builtin_scope := get_scope(b, Scope_ID(1)) // builtins is always scope 1
	if builtin_scope == nil {
		return INVALID_SYMBOL, false
	}
	if sym_id, ok := builtin_scope.symbols[name]; ok {
		return sym_id, true
	}
	return INVALID_SYMBOL, false
}
