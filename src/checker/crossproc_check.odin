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
//   PROC001 — Shared mutable state in multiprocessing (§22.1)
//   PROC002 — Unpicklable target in multiprocessing (§22.3)
//   PROC003 — Celery task with non-serializable argument types (§22.2)
//   PROC004 — Celery task accessing ORM lazy-loaded relationships

PROC_TARGET_METHODS :: [?]string{"map", "apply", "apply_async", "starmap", "imap", "map_async"}

analyze_crossproc :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	// Check for multiprocessing / celery imports
	has_mp := false
	has_celery := false
	for &imp in bind_result.imports {
		if imp.module_name == "multiprocessing" || imp.module_name == "concurrent.futures" {
			has_mp = true
		}
		if imp.module_name == "celery" || imp.module_name == "celery.app" {
			has_celery = true
		}
	}

	// §22.2: Celery task validation
	if has_celery {
		check_celery_tasks(module, bind_result, file_path, diagnostics, allocator)
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

// ==================== §22.2 Celery Task Validation ====================

// ORM lazy-load attribute access patterns
ORM_LAZY_ATTRS :: [?]string{"user", "author", "parent", "children", "items", "orders", "posts", "comments", "profile", "roles", "permissions", "tags", "category", "group", "members"}

// Detect @celery.task or @app.task decorated functions, check for:
// PROC003: non-serializable default arguments (db connections, file handles)
// PROC004: ORM lazy-load attribute access (DetachedInstanceError risk)
check_celery_tasks :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	for stmt in module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			if _has_celery_task_decorator(s.decorator_list) {
				_check_celery_func(s, file_path, diagnostics, allocator)
			}
		case ^parser.Async_Func_Def:
			if _has_celery_task_decorator(s.decorator_list) {
				_check_celery_async_func(s, file_path, diagnostics, allocator)
			}
		}
	}
}

_has_celery_task_decorator :: proc(decorators: []parser.Expr) -> bool {
	for d in decorators {
		// @celery.task or @app.task
		#partial switch e in d {
		case ^parser.Attribute_Expr:
			if e.attr == "task" { return true }
		case ^parser.Name_Expr:
			if e.id == "task" { return true }
		case ^parser.Call_Expr:
			// @celery.task(...) or @app.task(...)
			#partial switch f in e.func {
			case ^parser.Attribute_Expr:
				if f.attr == "task" { return true }
			case ^parser.Name_Expr:
				if f.id == "task" { return true }
			}
		}
	}
	return false
}

_check_celery_func :: proc(func: ^parser.Func_Def, file_path: string, diagnostics: ^[dynamic]core.Diagnostic, allocator: mem.Allocator) {
	// PROC004: Check body for ORM lazy-load access patterns
	// Pattern: x.relationship_attr where x is a parameter or result of .query.get() / .objects.get()
	_check_orm_lazy_load(func.body, func.name, file_path, diagnostics)
}

_check_celery_async_func :: proc(func: ^parser.Async_Func_Def, file_path: string, diagnostics: ^[dynamic]core.Diagnostic, allocator: mem.Allocator) {
	_check_orm_lazy_load(func.body, func.name, file_path, diagnostics)
}

_check_orm_lazy_load :: proc(stmts: []parser.Stmt, task_name: string, file_path: string, diagnostics: ^[dynamic]core.Diagnostic) {
	// Find variables assigned from .query.get() or .objects.get()
	orm_vars := make(map[string]bool, 4, context.temp_allocator)

	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Assign:
			if len(s.targets) == 1 {
				if name, ok := s.targets[0].(^parser.Name_Expr); ok {
					if _is_orm_query(s.value) {
						orm_vars[name.id] = true
					}
				}
			}
			// Check RHS for lazy-load access
			_check_lazy_access(s.value, orm_vars, task_name, file_path, diagnostics)
		case ^parser.Expr_Stmt:
			_check_lazy_access(s.value, orm_vars, task_name, file_path, diagnostics)
		case ^parser.Return_Stmt:
			if s.value != nil { _check_lazy_access(s.value, orm_vars, task_name, file_path, diagnostics) }
		case ^parser.If_Stmt:
			_check_orm_lazy_load(s.body, task_name, file_path, diagnostics)
			_check_orm_lazy_load(s.orelse, task_name, file_path, diagnostics)
		case ^parser.For_Stmt:
			_check_orm_lazy_load(s.body, task_name, file_path, diagnostics)
		}
	}
}

_is_orm_query :: proc(expr: parser.Expr) -> bool {
	if expr == nil { return false }
	// Detect: Model.query.get(id), Model.objects.get(id), session.query(Model).get(id)
	call, ok := expr.(^parser.Call_Expr)
	if !ok { return false }
	attr, aok := call.func.(^parser.Attribute_Expr)
	if !aok { return false }
	return attr.attr == "get" || attr.attr == "first" || attr.attr == "one" || attr.attr == "get_or_404"
}

_check_lazy_access :: proc(expr: parser.Expr, orm_vars: map[string]bool, task_name: string, file_path: string, diagnostics: ^[dynamic]core.Diagnostic) {
	if expr == nil { return }
	#partial switch e in expr {
	case ^parser.Attribute_Expr:
		// Check: orm_var.lazy_attr
		if name, ok := e.value.(^parser.Name_Expr); ok {
			if name.id in orm_vars {
				for lazy_attr in ORM_LAZY_ATTRS {
					if e.attr == lazy_attr {
						append(diagnostics, core.Diagnostic{
							severity = .Error,
							location = core.Location{
								file   = file_path,
								line   = int(e.loc.line),
								column = int(e.loc.col),
							},
							code = "PROC004",
							what = fmt.tprintf("lazy-loaded attribute '.%s' accessed in Celery task '%s'", e.attr, task_name),
							why  = "Celery tasks run in a different process — ORM objects may be detached from the session, causing DetachedInstanceError",
							fix  = "eagerly load relationships with .options(joinedload(...)) or pass IDs instead of ORM objects",
						})
						break
					}
				}
			}
		}
		// Recurse
		_check_lazy_access(e.value, orm_vars, task_name, file_path, diagnostics)
	case ^parser.Call_Expr:
		_check_lazy_access(e.func, orm_vars, task_name, file_path, diagnostics)
		for arg in e.args { _check_lazy_access(arg, orm_vars, task_name, file_path, diagnostics) }
	case ^parser.Bin_Op_Expr:
		_check_lazy_access(e.left, orm_vars, task_name, file_path, diagnostics)
		_check_lazy_access(e.right, orm_vars, task_name, file_path, diagnostics)
	}
}
