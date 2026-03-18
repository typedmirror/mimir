package checker

import "core:fmt"
import "core:mem"

import parser "mimir:parser"
import binder "mimir:binder"
import core   "mimir:core"

// ==================== Cross-Process Analysis (§22) ====================
//
// Post-inference analysis pass for multiprocessing anti-patterns.
//
// Diagnostics:
//   PROC001 — Shared mutable state in multiprocessing: module-level mutable
//   PROC002 — Unpicklable target in multiprocessing: lambda, nested function,
//             or generator used as Pool.map/apply target (§22.3)
//             (dict, list, set) modified in a function that's used as a
//             multiprocessing target. Each process gets a copy — mutations
//             are not shared.

PROC_TARGET_METHODS :: [?]string{"map", "apply", "apply_async", "starmap", "imap", "map_async"}

analyze_crossproc :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	// Check for multiprocessing import
	has_mp := false
	for &imp in bind_result.imports {
		if imp.module_name == "multiprocessing" || imp.module_name == "concurrent.futures" {
			has_mp = true
			break
		}
	}
	if !has_mp { return }

	// §22.3: Check for unpicklable targets (lambda, nested functions)
	check_unpicklable_targets(module, bind_result, file_path, diagnostics, allocator)

	// Phase 1: collect module-level mutable variables (dict, list, set literals)
	module_mutables := make(map[string]parser.Src_Loc, 8, allocator)
	for stmt in module.body {
		#partial switch s in stmt {
		case ^parser.Assign:
			if len(s.targets) == 1 {
				if name, ok := s.targets[0].(^parser.Name_Expr); ok {
					if _is_mutable_literal(s.value) {
						module_mutables[name.id] = s.loc
					}
				}
			}
		}
	}
	if len(module_mutables) == 0 { return }

	// Phase 2: find functions that modify module-level mutables
	funcs_with_shared_mutation := make(map[string]parser.Src_Loc, 4, allocator)
	for stmt in module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			if loc, found := _func_mutates_module_var(s.body, module_mutables); found {
				funcs_with_shared_mutation[s.name] = loc
			}
		}
	}
	if len(funcs_with_shared_mutation) == 0 { return }

	// Phase 3: check if any of these functions are used as multiprocessing targets
	for stmt in module.body {
		_check_mp_target(stmt, funcs_with_shared_mutation, module_mutables, file_path, diagnostics)
	}

	// Also check inside functions
	for stmt in module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			for body_stmt in s.body {
				_check_mp_target(body_stmt, funcs_with_shared_mutation, module_mutables, file_path, diagnostics)
			}
		}
	}

}

_is_mutable_literal :: proc(expr: parser.Expr) -> bool {
	if expr == nil { return false }
	#partial switch _ in expr {
	case ^parser.Dict_Expr: return true
	case ^parser.List_Expr: return true
	case ^parser.Set_Expr:  return true
	}
	if c, ok := expr.(^parser.Call_Expr); ok {
		if n, nok := c.func.(^parser.Name_Expr); nok {
			return n.id == "dict" || n.id == "list" || n.id == "set"
		}
	}
	return false
}

_func_mutates_module_var :: proc(stmts: []parser.Stmt, module_mutables: map[string]parser.Src_Loc) -> (parser.Src_Loc, bool) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Assign:
			// dict[key] = val or list.append(val)
			if len(s.targets) == 1 {
				if sub, ok := s.targets[0].(^parser.Subscript_Expr); ok {
					if name, nok := sub.value.(^parser.Name_Expr); nok {
						if name.id in module_mutables { return s.loc, true }
					}
				}
			}
		case ^parser.Expr_Stmt:
			// list.append(val), dict.update(val), set.add(val)
			if call, ok := s.value.(^parser.Call_Expr); ok {
				if attr, aok := call.func.(^parser.Attribute_Expr); aok {
					if name, nok := attr.value.(^parser.Name_Expr); nok {
						if name.id in module_mutables {
							if attr.attr == "append" || attr.attr == "extend" || attr.attr == "update" || attr.attr == "add" || attr.attr == "pop" || attr.attr == "remove" || attr.attr == "clear" || attr.attr == "insert" {
								return s.loc, true
							}
						}
					}
				}
			}
		case ^parser.If_Stmt:
			if loc, found := _func_mutates_module_var(s.body, module_mutables); found { return loc, true }
			if loc, found := _func_mutates_module_var(s.orelse, module_mutables); found { return loc, true }
		case ^parser.For_Stmt:
			if loc, found := _func_mutates_module_var(s.body, module_mutables); found { return loc, true }
		}
	}
	return {}, false
}

_check_mp_target :: proc(
	stmt: parser.Stmt,
	funcs_with_mutation: map[string]parser.Src_Loc,
	module_mutables: map[string]parser.Src_Loc,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
) {
	#partial switch s in stmt {
	case ^parser.Assign:
		if s.value != nil {
			_check_mp_call(s.value, funcs_with_mutation, module_mutables, file_path, diagnostics)
		}
	case ^parser.Expr_Stmt:
		_check_mp_call(s.value, funcs_with_mutation, module_mutables, file_path, diagnostics)
	}
}

_check_mp_call :: proc(
	expr: parser.Expr,
	funcs_with_mutation: map[string]parser.Src_Loc,
	module_mutables: map[string]parser.Src_Loc,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
) {
	if expr == nil { return }
	call, ok := expr.(^parser.Call_Expr)
	if !ok { return }

	// Pool.map(target_func, data) or Pool().map(target_func, data)
	attr, attr_ok := call.func.(^parser.Attribute_Expr)
	if !attr_ok { return }

	is_pool_method := false
	for m in PROC_TARGET_METHODS {
		if attr.attr == m { is_pool_method = true; break }
	}
	if !is_pool_method { return }

	// First argument is the target function
	if len(call.args) < 1 { return }
	target_name, name_ok := call.args[0].(^parser.Name_Expr)
	if !name_ok { return }

	if mutation_loc, has_mutation := funcs_with_mutation[target_name.id]; has_mutation {
		append(diagnostics, core.Diagnostic{
			severity = .Error,
			location = core.Location{
				file   = file_path,
				line   = int(call.loc.line),
				column = int(call.loc.col),
			},
			code = "PROC001",
			what = fmt.tprintf("shared mutable state: '%s' modifies a module-level variable in a multiprocessing context", target_name.id),
			why  = "each worker process gets its own copy of module-level data — mutations are not shared between processes",
			fix  = "use multiprocessing.Manager().dict() or multiprocessing.Queue for shared state",
		})
	}
}

// §22.3: PROC002 — detect unpicklable objects as multiprocessing targets
check_unpicklable_targets :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	// Check for multiprocessing import
	has_mp := false
	for &imp in bind_result.imports {
		if imp.module_name == "multiprocessing" || imp.module_name == "concurrent.futures" {
			has_mp = true
			break
		}
	}
	if !has_mp { return }

	// Collect nested function names (defined inside other functions)
	nested_funcs := make(map[string]bool, 8, allocator)
	_find_nested_funcs(module.body, &nested_funcs, false)

	// Scan for Pool.map/apply calls with lambda or nested function targets
	_scan_for_unpicklable(module.body, nested_funcs, file_path, diagnostics, allocator)
}

_find_nested_funcs :: proc(stmts: []parser.Stmt, nested: ^map[string]bool, in_func: bool) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			if in_func {
				nested[s.name] = true
			}
			_find_nested_funcs(s.body, nested, true)
		case ^parser.Class_Def:
			_find_nested_funcs(s.body, nested, in_func)
		case ^parser.If_Stmt:
			_find_nested_funcs(s.body, nested, in_func)
			_find_nested_funcs(s.orelse, nested, in_func)
		case ^parser.For_Stmt:
			_find_nested_funcs(s.body, nested, in_func)
		}
	}
}

_scan_for_unpicklable :: proc(
	stmts: []parser.Stmt,
	nested_funcs: map[string]bool,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Expr_Stmt:
			_check_unpicklable_call(s.value, nested_funcs, file_path, diagnostics)
		case ^parser.Assign:
			if s.value != nil {
				_check_unpicklable_call(s.value, nested_funcs, file_path, diagnostics)
			}
		case ^parser.Func_Def:
			_scan_for_unpicklable(s.body, nested_funcs, file_path, diagnostics, allocator)
		case ^parser.If_Stmt:
			_scan_for_unpicklable(s.body, nested_funcs, file_path, diagnostics, allocator)
			_scan_for_unpicklable(s.orelse, nested_funcs, file_path, diagnostics, allocator)
		case ^parser.For_Stmt:
			_scan_for_unpicklable(s.body, nested_funcs, file_path, diagnostics, allocator)
		}
	}
}

_check_unpicklable_call :: proc(
	expr: parser.Expr,
	nested_funcs: map[string]bool,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
) {
	if expr == nil { return }
	call, ok := expr.(^parser.Call_Expr)
	if !ok { return }

	attr, attr_ok := call.func.(^parser.Attribute_Expr)
	if !attr_ok { return }

	is_pool_method := false
	for m in PROC_TARGET_METHODS {
		if attr.attr == m { is_pool_method = true; break }
	}
	if !is_pool_method { return }
	if len(call.args) < 1 { return }

	// Check if first arg is a lambda
	if _, is_lambda := call.args[0].(^parser.Lambda_Expr); is_lambda {
		append(diagnostics, core.Diagnostic{
			severity = .Error,
			location = core.Location{
				file   = file_path,
				line   = int(call.loc.line),
				column = int(call.loc.col),
			},
			code = "PROC002",
			what = "lambda used as multiprocessing target — cannot be pickled",
			why  = "multiprocessing sends functions to worker processes via pickle, but lambda functions are not picklable",
			fix  = "define a top-level named function instead of a lambda",
		})
		return
	}

	// Check if first arg is a nested function
	if name, is_name := call.args[0].(^parser.Name_Expr); is_name {
		if name.id in nested_funcs {
			append(diagnostics, core.Diagnostic{
				severity = .Error,
				location = core.Location{
					file   = file_path,
					line   = int(call.loc.line),
					column = int(call.loc.col),
				},
				code = "PROC002",
				what = fmt.tprintf("nested function '%s' used as multiprocessing target — cannot be pickled", name.id),
				why  = "multiprocessing sends functions to worker processes via pickle, but locally-defined functions are not picklable",
				fix  = "move the function to module level",
			})
		}
	}
}
