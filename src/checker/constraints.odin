package checker

import "core:mem"

import parser "mimir:parser"
import binder "mimir:binder"
import flow   "mimir:flow"
import core   "mimir:core"

// ==================== Constraint Variables ====================

Constraint_Var :: distinct u32
INVALID_CONSTRAINT_VAR :: Constraint_Var(0)

Constraint_Var_Info :: struct {
	id:           Constraint_Var,
	symbol_id:    binder.Symbol_ID,
	scope_id:     binder.Scope_ID,
	forward_type: Type_ID, // From forward inference (initialization)
}

// ==================== Constraint Types ====================

// Usage constraints — what operations were observed on a symbol.
// Extensible: ecosystem modules add variants (Shape_Eq, Column_Has, etc.)
Constraint :: union {
	Has_Method,
	Has_Attr,
	Callable_With,
	Iterable_Of,
	Subscriptable,
}

Has_Method :: struct {
	var:         Constraint_Var,
	method_name: string,
	arg_types:   []Type_ID,
	return_type: Type_ID,
	loc:         parser.Src_Loc,
}

Has_Attr :: struct {
	var:       Constraint_Var,
	attr_name: string,
	attr_type: Type_ID,
	loc:       parser.Src_Loc,
}

Callable_With :: struct {
	var:         Constraint_Var,
	arg_types:   []Type_ID,
	return_type: Type_ID,
	loc:         parser.Src_Loc,
}

Iterable_Of :: struct {
	var:          Constraint_Var,
	element_type: Type_ID,
	loc:          parser.Src_Loc,
}

Subscriptable :: struct {
	var:        Constraint_Var,
	key_type:   Type_ID,
	value_type: Type_ID,
	loc:        parser.Src_Loc,
}

// ==================== Constraint Set ====================

Constraint_Set :: struct {
	vars:            [dynamic]Constraint_Var_Info,
	constraints:     [dynamic]Constraint,
	sym_to_var:      map[binder.Symbol_ID]Constraint_Var,
	var_constraints: map[Constraint_Var][dynamic]int, // var → constraint indices
	allocator:       mem.Allocator,
}

init_constraint_set :: proc(allocator: mem.Allocator) -> Constraint_Set {
	cs: Constraint_Set
	cs.vars = make([dynamic]Constraint_Var_Info, 0, 16, allocator)
	cs.constraints = make([dynamic]Constraint, 0, 32, allocator)
	cs.sym_to_var = make(map[binder.Symbol_ID]Constraint_Var, 16, allocator)
	cs.var_constraints = make(map[Constraint_Var][dynamic]int, 16, allocator)
	cs.allocator = allocator
	return cs
}

get_or_create_var :: proc(cs: ^Constraint_Set, sym_id: binder.Symbol_ID, scope_id: binder.Scope_ID, forward_type: Type_ID) -> Constraint_Var {
	if v, ok := cs.sym_to_var[sym_id]; ok {
		return v
	}
	id := Constraint_Var(u32(len(cs.vars)) + 1)
	append(&cs.vars, Constraint_Var_Info{
		id           = id,
		symbol_id    = sym_id,
		scope_id     = scope_id,
		forward_type = forward_type,
	})
	cs.sym_to_var[sym_id] = id
	cs.var_constraints[id] = make([dynamic]int, 0, 4, cs.allocator)
	return id
}

add_constraint :: proc(cs: ^Constraint_Set, c: Constraint) {
	idx := len(cs.constraints)
	append(&cs.constraints, c)

	// Index by constraint variable
	var_id: Constraint_Var
	#partial switch cv in c {
	case Has_Method:    var_id = cv.var
	case Has_Attr:      var_id = cv.var
	case Callable_With: var_id = cv.var
	case Iterable_Of:   var_id = cv.var
	case Subscriptable: var_id = cv.var
	}
	if var_id != INVALID_CONSTRAINT_VAR {
		if vc, ok := &cs.var_constraints[var_id]; ok {
			append(vc, idx)
		}
	}
}

// ==================== Builtin Method Table ====================

Method_Signature :: struct {
	params:      []Type_ID,
	return_type: Type_ID,
}

Method_Owner :: struct {
	owner_type: Type_ID,
	signature:  Method_Signature,
}

Builtin_Method_Table :: struct {
	by_name: map[string][]Method_Owner,
}

init_method_table :: proc(reg: ^Type_Registry) -> Builtin_Method_Table {
	mt: Builtin_Method_Table
	mt.by_name = make(map[string][]Method_Owner, 64, reg.allocator)

	list_str := make_list_type(reg, TYPE_STR)
	list_bytes := make_list_type(reg, TYPE_BYTES)

	// str methods
	add_method(&mt, "split",      TYPE_STR, {}, list_str, reg.allocator)
	add_method(&mt, "rsplit",     TYPE_STR, {}, list_str, reg.allocator)
	add_method(&mt, "strip",      TYPE_STR, {}, TYPE_STR, reg.allocator)
	add_method(&mt, "lstrip",     TYPE_STR, {}, TYPE_STR, reg.allocator)
	add_method(&mt, "rstrip",     TYPE_STR, {}, TYPE_STR, reg.allocator)
	add_method(&mt, "join",       TYPE_STR, {}, TYPE_STR, reg.allocator)
	add_method(&mt, "replace",    TYPE_STR, {TYPE_STR, TYPE_STR}, TYPE_STR, reg.allocator)
	add_method(&mt, "startswith", TYPE_STR, {TYPE_STR}, TYPE_BOOL, reg.allocator)
	add_method(&mt, "endswith",   TYPE_STR, {TYPE_STR}, TYPE_BOOL, reg.allocator)
	add_method(&mt, "upper",      TYPE_STR, {}, TYPE_STR, reg.allocator)
	add_method(&mt, "lower",      TYPE_STR, {}, TYPE_STR, reg.allocator)
	add_method(&mt, "title",      TYPE_STR, {}, TYPE_STR, reg.allocator)
	add_method(&mt, "encode",     TYPE_STR, {}, TYPE_BYTES, reg.allocator)
	add_method(&mt, "find",       TYPE_STR, {TYPE_STR}, TYPE_INT, reg.allocator)
	add_method(&mt, "index",      TYPE_STR, {TYPE_STR}, TYPE_INT, reg.allocator)
	add_method(&mt, "count",      TYPE_STR, {TYPE_STR}, TYPE_INT, reg.allocator)
	add_method(&mt, "format",     TYPE_STR, {}, TYPE_STR, reg.allocator)
	add_method(&mt, "isdigit",    TYPE_STR, {}, TYPE_BOOL, reg.allocator)
	add_method(&mt, "isalpha",    TYPE_STR, {}, TYPE_BOOL, reg.allocator)
	add_method(&mt, "zfill",      TYPE_STR, {TYPE_INT}, TYPE_STR, reg.allocator)
	add_method(&mt, "center",     TYPE_STR, {TYPE_INT}, TYPE_STR, reg.allocator)
	add_method(&mt, "ljust",      TYPE_STR, {TYPE_INT}, TYPE_STR, reg.allocator)
	add_method(&mt, "rjust",      TYPE_STR, {TYPE_INT}, TYPE_STR, reg.allocator)

	// bytes methods
	add_method(&mt, "decode",     TYPE_BYTES, {}, TYPE_STR, reg.allocator)
	add_method(&mt, "split",      TYPE_BYTES, {}, list_bytes, reg.allocator)
	add_method(&mt, "strip",      TYPE_BYTES, {}, TYPE_BYTES, reg.allocator)
	add_method(&mt, "replace",    TYPE_BYTES, {TYPE_BYTES, TYPE_BYTES}, TYPE_BYTES, reg.allocator)
	add_method(&mt, "startswith", TYPE_BYTES, {TYPE_BYTES}, TYPE_BOOL, reg.allocator)
	add_method(&mt, "endswith",   TYPE_BYTES, {TYPE_BYTES}, TYPE_BOOL, reg.allocator)
	add_method(&mt, "hex",        TYPE_BYTES, {}, TYPE_STR, reg.allocator)
	add_method(&mt, "find",       TYPE_BYTES, {TYPE_BYTES}, TYPE_INT, reg.allocator)

	// list methods (generic — use TYPE_ANY as element placeholder)
	add_method(&mt, "append", TYPE_ANY, {}, TYPE_NONE, reg.allocator)   // list marker
	add_method(&mt, "extend", TYPE_ANY, {}, TYPE_NONE, reg.allocator)
	add_method(&mt, "insert", TYPE_ANY, {TYPE_INT}, TYPE_NONE, reg.allocator)
	add_method(&mt, "pop",    TYPE_ANY, {}, TYPE_ANY, reg.allocator)
	add_method(&mt, "remove", TYPE_ANY, {}, TYPE_NONE, reg.allocator)
	add_method(&mt, "sort",   TYPE_ANY, {}, TYPE_NONE, reg.allocator)
	add_method(&mt, "reverse",TYPE_ANY, {}, TYPE_NONE, reg.allocator)
	add_method(&mt, "copy",   TYPE_ANY, {}, TYPE_ANY, reg.allocator)

	// dict methods
	add_method(&mt, "keys",       TYPE_ANY, {}, TYPE_ANY, reg.allocator) // dict marker
	add_method(&mt, "values",     TYPE_ANY, {}, TYPE_ANY, reg.allocator)
	add_method(&mt, "items",      TYPE_ANY, {}, TYPE_ANY, reg.allocator)
	add_method(&mt, "get",        TYPE_ANY, {}, TYPE_ANY, reg.allocator)
	add_method(&mt, "update",     TYPE_ANY, {}, TYPE_NONE, reg.allocator)
	add_method(&mt, "setdefault", TYPE_ANY, {}, TYPE_ANY, reg.allocator)
	add_method(&mt, "clear",      TYPE_ANY, {}, TYPE_NONE, reg.allocator)

	// set methods
	add_method(&mt, "add",          TYPE_ANY, {}, TYPE_NONE, reg.allocator) // set marker
	add_method(&mt, "discard",      TYPE_ANY, {}, TYPE_NONE, reg.allocator)
	add_method(&mt, "union",        TYPE_ANY, {}, TYPE_ANY, reg.allocator)
	add_method(&mt, "intersection", TYPE_ANY, {}, TYPE_ANY, reg.allocator)
	add_method(&mt, "difference",   TYPE_ANY, {}, TYPE_ANY, reg.allocator)
	add_method(&mt, "issubset",     TYPE_ANY, {}, TYPE_BOOL, reg.allocator)
	add_method(&mt, "issuperset",   TYPE_ANY, {}, TYPE_BOOL, reg.allocator)

	return mt
}

add_method :: proc(mt: ^Builtin_Method_Table, name: string, owner: Type_ID, params: []Type_ID, ret: Type_ID, allocator: mem.Allocator) {
	entry := Method_Owner{
		owner_type = owner,
		signature  = Method_Signature{
			params      = params,
			return_type = ret,
		},
	}
	if existing, ok := mt.by_name[name]; ok {
		new_list := make([]Method_Owner, len(existing) + 1, allocator)
		for e, i in existing { new_list[i] = e }
		new_list[len(existing)] = entry
		mt.by_name[name] = new_list
	} else {
		list := make([]Method_Owner, 1, allocator)
		list[0] = entry
		mt.by_name[name] = list
	}
}

// ==================== Constraint Collection ====================

// Context passed through the AST walker during constraint collection
Collect_Context :: struct {
	cs:           ^Constraint_Set,
	bind_result:  ^binder.Bind_Result,
	reg:          ^Type_Registry,
	expr_types:   ^map[rawptr]Type_ID,
	unknown_syms: map[binder.Symbol_ID]bool, // symbols to track
	scope_id:     binder.Scope_ID,
}

collect_scope_constraints :: proc(
	cfg: ^flow.CFG,
	bind_result: ^binder.Bind_Result,
	reg: ^Type_Registry,
	envs: []Type_Env,
	expr_types: ^map[rawptr]Type_ID,
	unknown_params: []binder.Symbol_ID,
	allocator: mem.Allocator,
) -> Constraint_Set {
	cs := init_constraint_set(allocator)

	// Build lookup set for unknown params
	unknown_syms := make(map[binder.Symbol_ID]bool, len(unknown_params), allocator)
	for sym_id in unknown_params {
		unknown_syms[sym_id] = true
		get_or_create_var(&cs, sym_id, cfg.scope_id, TYPE_UNKNOWN)
	}

	// Walk all blocks' statements collecting constraints
	ctx := Collect_Context{
		cs           = &cs,
		bind_result  = bind_result,
		reg          = reg,
		expr_types   = expr_types,
		unknown_syms = unknown_syms,
		scope_id     = cfg.scope_id,
	}

	visitor := core.AST_Visitor{
		visit_expr = collect_expr_constraints,
		ctx        = rawptr(&ctx),
	}

	for &block in cfg.blocks {
		if !block.is_reachable { continue }
		for stmt in block.stmts {
			// Also check for-loop iteration targets
			collect_stmt_constraints(stmt, &ctx)
			core.walk_stmt(&visitor, stmt)
		}
	}

	return cs
}

// Check statement-level patterns (for loops → Iterable_Of)
collect_stmt_constraints :: proc(stmt: parser.Stmt, ctx: ^Collect_Context) {
	#partial switch s in stmt {
	case ^parser.For_Stmt:
		// `for x in iter:` → Iterable_Of(iter, typeof(x))
		collect_iter_constraint(s.iter, s.target, ctx)
	case ^parser.Async_For:
		collect_iter_constraint(s.iter, s.target, ctx)
	}
}

collect_iter_constraint :: proc(iter_expr: parser.Expr, target: parser.Expr, ctx: ^Collect_Context) {
	if iter_expr == nil { return }
	sym_id := resolve_to_symbol(iter_expr, ctx.bind_result)
	if sym_id == binder.INVALID_SYMBOL { return }
	if sym_id not_in ctx.unknown_syms { return }

	// Get inferred element type from the target
	elem_type := TYPE_UNKNOWN
	if target != nil {
		if et, ok := ctx.expr_types[rawptr_from_expr(target)]; ok {
			elem_type = et
		}
	}

	cv := get_or_create_var(ctx.cs, sym_id, ctx.scope_id, TYPE_UNKNOWN)
	add_constraint(ctx.cs, Iterable_Of{
		var          = cv,
		element_type = elem_type,
		loc          = get_expr_loc(iter_expr),
	})
}

// Expression-level constraint visitor callback
collect_expr_constraints :: proc(expr: parser.Expr, raw_ctx: rawptr) {
	if expr == nil { return }
	ctx := cast(^Collect_Context)raw_ctx

	#partial switch e in expr {
	case ^parser.Call_Expr:
		// x.method(args) → Has_Method
		if attr, ok := e.func.(^parser.Attribute_Expr); ok {
			sym_id := resolve_to_symbol(attr.value, ctx.bind_result)
			if sym_id != binder.INVALID_SYMBOL && sym_id in ctx.unknown_syms {
				// Collect arg types
				arg_types := make([]Type_ID, len(e.args), ctx.cs.allocator)
				for a, i in e.args {
					if t, found := ctx.expr_types[rawptr_from_expr(a)]; found {
						arg_types[i] = t
					} else {
						arg_types[i] = TYPE_UNKNOWN
					}
				}

				// Get return type from expr_types
				ret_type := TYPE_UNKNOWN
				if t, found := ctx.expr_types[rawptr_from_expr(expr)]; found {
					ret_type = t
				}

				cv := get_or_create_var(ctx.cs, sym_id, ctx.scope_id, TYPE_UNKNOWN)
				add_constraint(ctx.cs, Has_Method{
					var         = cv,
					method_name = attr.attr,
					arg_types   = arg_types,
					return_type = ret_type,
					loc         = attr.loc,
				})
			}
		}

		// x(args) → Callable_With (when x is an unknown param called directly)
		if name, ok := e.func.(^parser.Name_Expr); ok {
			sym_id, ref_ok := binder.get_ref(ctx.bind_result, rawptr(name))
			if ref_ok && sym_id in ctx.unknown_syms {
				arg_types := make([]Type_ID, len(e.args), ctx.cs.allocator)
				for a, i in e.args {
					if t, found := ctx.expr_types[rawptr_from_expr(a)]; found {
						arg_types[i] = t
					} else {
						arg_types[i] = TYPE_UNKNOWN
					}
				}
				ret_type := TYPE_UNKNOWN
				if t, found := ctx.expr_types[rawptr_from_expr(expr)]; found {
					ret_type = t
				}

				cv := get_or_create_var(ctx.cs, sym_id, ctx.scope_id, TYPE_UNKNOWN)
				add_constraint(ctx.cs, Callable_With{
					var         = cv,
					arg_types   = arg_types,
					return_type = ret_type,
					loc         = name.loc,
				})
			}
		}

	case ^parser.Attribute_Expr:
		// x.attr (non-call) → Has_Attr
		sym_id := resolve_to_symbol(e.value, ctx.bind_result)
		if sym_id != binder.INVALID_SYMBOL && sym_id in ctx.unknown_syms {
			attr_type := TYPE_UNKNOWN
			if t, found := ctx.expr_types[rawptr_from_expr(expr)]; found {
				attr_type = t
			}

			cv := get_or_create_var(ctx.cs, sym_id, ctx.scope_id, TYPE_UNKNOWN)
			add_constraint(ctx.cs, Has_Attr{
				var       = cv,
				attr_name = e.attr,
				attr_type = attr_type,
				loc       = e.loc,
			})
		}

	case ^parser.Subscript_Expr:
		// x[key] → Subscriptable
		sym_id := resolve_to_symbol(e.value, ctx.bind_result)
		if sym_id != binder.INVALID_SYMBOL && sym_id in ctx.unknown_syms {
			key_type := TYPE_UNKNOWN
			if t, found := ctx.expr_types[rawptr_from_expr(e.slice)]; found {
				key_type = t
			}
			value_type := TYPE_UNKNOWN
			if t, found := ctx.expr_types[rawptr_from_expr(expr)]; found {
				value_type = t
			}

			cv := get_or_create_var(ctx.cs, sym_id, ctx.scope_id, TYPE_UNKNOWN)
			add_constraint(ctx.cs, Subscriptable{
				var        = cv,
				key_type   = key_type,
				value_type = value_type,
				loc        = e.loc,
			})
		}
	}
}

// ==================== Helpers ====================

resolve_to_symbol :: proc(expr: parser.Expr, bind_result: ^binder.Bind_Result) -> binder.Symbol_ID {
	if expr == nil { return binder.INVALID_SYMBOL }
	if name, ok := expr.(^parser.Name_Expr); ok {
		sym_id, ref_ok := binder.get_ref(bind_result, rawptr(name))
		if ref_ok { return sym_id }
	}
	return binder.INVALID_SYMBOL
}

rawptr_from_expr :: proc(expr: parser.Expr) -> rawptr {
	#partial switch e in expr {
	case ^parser.Name_Expr:         return rawptr(e)
	case ^parser.Call_Expr:         return rawptr(e)
	case ^parser.Attribute_Expr:    return rawptr(e)
	case ^parser.Subscript_Expr:    return rawptr(e)
	case ^parser.Bin_Op_Expr:       return rawptr(e)
	case ^parser.Unary_Op_Expr:     return rawptr(e)
	case ^parser.Bool_Op_Expr:      return rawptr(e)
	case ^parser.Compare_Expr:      return rawptr(e)
	case ^parser.If_Expr:           return rawptr(e)
	case ^parser.Lambda_Expr:       return rawptr(e)
	case ^parser.Constant_Expr:     return rawptr(e)
	case ^parser.List_Expr:         return rawptr(e)
	case ^parser.Dict_Expr:         return rawptr(e)
	case ^parser.Set_Expr:          return rawptr(e)
	case ^parser.Tuple_Expr:        return rawptr(e)
	case ^parser.Joined_Str:        return rawptr(e)
	case ^parser.Formatted_Value:   return rawptr(e)
	case ^parser.Starred_Expr:      return rawptr(e)
	case ^parser.Named_Expr:        return rawptr(e)
	case ^parser.Await_Expr:        return rawptr(e)
	case ^parser.Yield_Expr:        return rawptr(e)
	case ^parser.Yield_From_Expr:   return rawptr(e)
	case ^parser.Slice_Expr:        return rawptr(e)
	case ^parser.List_Comp:         return rawptr(e)
	case ^parser.Set_Comp:          return rawptr(e)
	case ^parser.Dict_Comp:         return rawptr(e)
	case ^parser.Generator_Expr:    return rawptr(e)
	}
	return nil
}

get_expr_loc :: proc(expr: parser.Expr) -> parser.Src_Loc {
	#partial switch e in expr {
	case ^parser.Name_Expr:       return e.loc
	case ^parser.Call_Expr:       return e.loc
	case ^parser.Attribute_Expr:  return e.loc
	case ^parser.Subscript_Expr:  return e.loc
	case ^parser.Constant_Expr:   return e.loc
	}
	return {}
}
