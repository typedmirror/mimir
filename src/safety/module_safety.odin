package safety

import "core:fmt"
import "core:strings"
import parser "mimir:parser"
import binder "mimir:binder"
import core "mimir:core"

// SAF003 — Import side effects: module-level function calls
check_import_side_effect :: proc(ctx: ^Safety_Context) {
	for stmt in ctx.module.body {
		// Skip statements inside if __name__ == "__main__" guard
		if is_main_guard(stmt) { continue }

		#partial switch s in stmt {
		case ^parser.Expr_Stmt:
			if call, is_call := s.value.(^parser.Call_Expr); is_call {
				if !is_safe_module_call_standalone(call) {
					name := call_name(call)
					append(&ctx.diagnostics, core.Diagnostic{
						severity = .Warning,
						location = core.Location{
							file   = ctx.file_path,
							line   = int(call.loc.line),
							column = int(call.loc.col),
						},
						what = fmt.tprintf("function call '%s' at module level has side effects", name),
						why  = "module-level calls execute on import, causing unexpected side effects",
						fix  = "move this call inside a function or 'if __name__ == \"__main__\"' guard",
						code = "SAF003",
					})
				}
			}
		case ^parser.Assign:
			if call, is_call := s.value.(^parser.Call_Expr); is_call {
				if !is_safe_module_call(call) {
					name := call_name(call)
					append(&ctx.diagnostics, core.Diagnostic{
						severity = .Warning,
						location = core.Location{
							file   = ctx.file_path,
							line   = int(call.loc.line),
							column = int(call.loc.col),
						},
						what = fmt.tprintf("function call '%s' at module level has side effects", name),
						why  = "module-level calls execute on import, causing unexpected side effects",
						fix  = "move this call inside a function or 'if __name__ == \"__main__\"' guard",
						code = "SAF003",
					})
				}
			}
		}
	}
}

// SAF004 — Monkey-patching: attribute assignment on imported modules
check_monkey_patch :: proc(ctx: ^Safety_Context) {
	visitor := core.AST_Visitor{
		visit_stmt = proc(stmt: parser.Stmt, raw_ctx: rawptr) {
			ctx := cast(^Safety_Context)raw_ctx
			#partial switch s in stmt {
			case ^parser.Assign:
				for target in s.targets {
					check_monkey_patch_target(ctx, target)
				}
			}
		},
		ctx = rawptr(ctx),
	}
	core.walk_all_stmts(&visitor, ctx.module.body)
}

check_monkey_patch_target :: proc(ctx: ^Safety_Context, target: parser.Expr) {
	attr, is_attr := target.(^parser.Attribute_Expr)
	if !is_attr { return }

	// Check if the base is an imported name
	name, is_name := attr.value.(^parser.Name_Expr)
	if !is_name { return }

	// Look up in binder to see if it's imported
	for &sym in ctx.bind_result.symbols {
		if sym.name == name.id && .Is_Imported in sym.flags {
			append(&ctx.diagnostics, core.Diagnostic{
				severity = .Warning,
				location = core.Location{
					file   = ctx.file_path,
					line   = int(attr.loc.line),
					column = int(attr.loc.col),
				},
				what = fmt.tprintf("monkey-patching %s.%s", name.id, attr.attr),
				why  = "modifying imported module attributes affects all callers and breaks expectations",
				fix  = "create a wrapper function or use dependency injection instead",
				code = "SAF004",
			})
			return
		}
	}
}

// SAF005 — Global state mutation: functions mutating module-level mutable containers
check_global_state_mutation :: proc(ctx: ^Safety_Context) {
	// Build set of module-level mutable names
	module_mutables := collect_module_mutables(ctx)

	// Walk function bodies for mutations on those names
	for stmt in ctx.module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			check_mutations_in_body(ctx, s.body, module_mutables)
		case ^parser.Async_Func_Def:
			check_mutations_in_body(ctx, s.body, module_mutables)
		case ^parser.Class_Def:
			for class_stmt in s.body {
				#partial switch cs in class_stmt {
				case ^parser.Func_Def:
					check_mutations_in_body(ctx, cs.body, module_mutables)
				case ^parser.Async_Func_Def:
					check_mutations_in_body(ctx, cs.body, module_mutables)
				}
			}
		}
	}
}

Module_Mutable :: struct {
	name: string,
}

collect_module_mutables :: proc(ctx: ^Safety_Context) -> []Module_Mutable {
	result := make([dynamic]Module_Mutable, 0, 8, ctx.allocator)
	for stmt in ctx.module.body {
		#partial switch s in stmt {
		case ^parser.Assign:
			// Check if value is a mutable literal: dict, list, set
			if is_mutable_literal(s.value) {
				for target in s.targets {
					if name, is_name := target.(^parser.Name_Expr); is_name {
						append(&result, Module_Mutable{name = name.id})
					}
				}
			}
		}
	}
	return result[:]
}

is_mutable_literal :: proc(expr: parser.Expr) -> bool {
	if expr == nil { return false }
	#partial switch _ in expr {
	case ^parser.Dict_Expr: return true
	case ^parser.List_Expr: return true
	case ^parser.Set_Expr:  return true
	}
	return false
}

Mutation_Walk_Context :: struct {
	safety_ctx: ^Safety_Context,
	mutables:   []Module_Mutable,
}

check_mutations_in_body :: proc(ctx: ^Safety_Context, stmts: []parser.Stmt, mutables: []Module_Mutable) {
	mwc := Mutation_Walk_Context{safety_ctx = ctx, mutables = mutables}
	visitor := core.AST_Visitor{
		visit_stmt = proc(stmt: parser.Stmt, raw_ctx: rawptr) {
			mwc := cast(^Mutation_Walk_Context)raw_ctx
			ctx := mwc.safety_ctx
			mutables := mwc.mutables
			#partial switch s in stmt {
			case ^parser.Assign:
				for target in s.targets {
					if sub, is_sub := target.(^parser.Subscript_Expr); is_sub {
						if name, is_name := sub.value.(^parser.Name_Expr); is_name {
							if is_module_mutable(name.id, mutables) {
								emit_mutation(ctx, name.id, sub.loc)
							}
						}
					}
				}
			case ^parser.Expr_Stmt:
				if call, is_call := s.value.(^parser.Call_Expr); is_call {
					if attr, is_attr := call.func.(^parser.Attribute_Expr); is_attr {
						if is_mutating_method(attr.attr) {
							if name, is_name := attr.value.(^parser.Name_Expr); is_name {
								if is_module_mutable(name.id, mutables) {
									emit_mutation(ctx, name.id, call.loc)
								}
							}
						}
					}
				}
			}
		},
		ctx = rawptr(&mwc),
	}
	core.walk_all_stmts(&visitor, stmts)
}

is_module_mutable :: proc(name: string, mutables: []Module_Mutable) -> bool {
	for m in mutables {
		if m.name == name { return true }
	}
	return false
}

is_mutating_method :: proc(method: string) -> bool {
	MUTATING :: [?]string{"append", "extend", "insert", "pop", "remove", "clear", "update", "add", "discard", "setdefault"}
	for m in MUTATING {
		if method == m { return true }
	}
	return false
}

emit_mutation :: proc(ctx: ^Safety_Context, name: string, loc: parser.Src_Loc) {
	append(&ctx.diagnostics, core.Diagnostic{
		severity = .Warning,
		location = core.Location{
			file   = ctx.file_path,
			line   = int(loc.line),
			column = int(loc.col),
		},
		what = fmt.tprintf("mutates module-level variable '%s'", name),
		why  = "module-level mutable state is not thread-safe and makes reasoning about code harder",
		fix  = "pass the data as a parameter, use a class, or protect with a lock",
		code = "SAF005",
	})
}

// ==================== Helpers ====================

is_main_guard :: proc(stmt: parser.Stmt) -> bool {
	// if __name__ == "__main__":
	if_stmt, is_if := stmt.(^parser.If_Stmt)
	if !is_if { return false }

	cmp, is_cmp := if_stmt.test.(^parser.Compare_Expr)
	if !is_cmp { return false }

	// Left: __name__
	left_name, left_ok := cmp.left.(^parser.Name_Expr)
	if !left_ok || left_name.id != "__name__" { return false }

	// Comparator: "__main__"
	if len(cmp.comparators) != 1 { return false }
	if c, ok := cmp.comparators[0].(^parser.Constant_Expr); ok {
		if s, s_ok := c.value.(string); s_ok {
			return s == "__main__"
		}
	}

	return false
}

SAFE_BUILTINS :: [?]string{
	"dict", "list", "set", "tuple", "frozenset",
	"int", "float", "str", "bool", "bytes",
	"type", "object", "super", "len", "range",
	"print", "repr", "sorted", "reversed", "enumerate",
	"zip", "map", "filter", "min", "max", "sum", "abs",
	"isinstance", "issubclass", "hasattr", "getattr",
	"property", "staticmethod", "classmethod",
	"TypeVar", "Generic",
}

is_safe_module_call :: proc(call: ^parser.Call_Expr) -> bool {
	// Check simple name calls
	if name, is_name := call.func.(^parser.Name_Expr); is_name {
		for safe in SAFE_BUILTINS {
			if name.id == safe { return true }
		}
		// Capitalized = likely class constructor (for assigned context)
		if len(name.id) > 0 && name.id[0] >= 'A' && name.id[0] <= 'Z' {
			return true
		}
		return false
	}

	// Check attr calls: os.path.join(), Path(), etc.
	if attr, is_attr := call.func.(^parser.Attribute_Expr); is_attr {
		// namedtuple, dataclass decorators
		if attr.attr == "namedtuple" || attr.attr == "dataclass" { return true }
		// getLogger is safe
		if attr.attr == "getLogger" { return true }
		return false
	}

	return false
}

// Standalone call check: does NOT exempt capitalized names (standalone Setup() is suspicious)
is_safe_module_call_standalone :: proc(call: ^parser.Call_Expr) -> bool {
	if name, is_name := call.func.(^parser.Name_Expr); is_name {
		for safe in SAFE_BUILTINS {
			if name.id == safe { return true }
		}
		return false
	}
	if attr, is_attr := call.func.(^parser.Attribute_Expr); is_attr {
		if attr.attr == "namedtuple" || attr.attr == "dataclass" { return true }
		if attr.attr == "getLogger" { return true }
		return false
	}
	return false
}

call_name :: proc(call: ^parser.Call_Expr) -> string {
	if name, is_name := call.func.(^parser.Name_Expr); is_name {
		return name.id
	}
	if attr, is_attr := call.func.(^parser.Attribute_Expr); is_attr {
		if base_name, bn_ok := attr.value.(^parser.Name_Expr); bn_ok {
			return fmt.tprintf("%s.%s", base_name.id, attr.attr)
		}
		return attr.attr
	}
	return "<call>"
}
