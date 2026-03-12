package binder

import parser "mimir:parser"

Symbol_ID :: distinct u32
INVALID_SYMBOL :: Symbol_ID(0)

Symbol_Kind :: enum u8 {
	Variable,
	Function,
	Class,
	Parameter,
	Import,
	Type_Param,
}

Symbol_Flag :: enum u8 {
	Is_Global,
	Is_Nonlocal,
	Is_Assigned,
	Is_Imported,
	Is_Annotated,
	Is_Param,
}
Symbol_Flags :: bit_set[Symbol_Flag; u8]

Symbol :: struct {
	id:       Symbol_ID,
	name:     string,
	kind:     Symbol_Kind,
	flags:    Symbol_Flags,
	scope_id: Scope_ID,
	def_loc:  parser.Src_Loc,
}

add_symbol :: proc(b: ^Binder, name: string, kind: Symbol_Kind, flags: Symbol_Flags, loc: parser.Src_Loc) -> Symbol_ID {
	scope_id := current_scope(b)
	scope := get_scope(b, scope_id)
	if scope == nil { return Symbol_ID(0) }

	// If symbol already exists in this scope, return existing
	if existing, ok := scope.symbols[name]; ok {
		sym := get_symbol(b, existing)
		sym.flags += flags
		return existing
	}

	b.next_sym_id += 1
	id := Symbol_ID(b.next_sym_id)

	append(&b.result.symbols, Symbol{
		id       = id,
		name     = name,
		kind     = kind,
		flags    = flags,
		scope_id = scope_id,
		def_loc  = loc,
	})

	scope.symbols[name] = id
	return id
}

get_symbol :: proc(b: ^Binder, id: Symbol_ID) -> ^Symbol {
	idx := int(id) - 1
	if idx < 0 || idx >= len(b.result.symbols) {
		return nil
	}
	return &b.result.symbols[idx]
}
