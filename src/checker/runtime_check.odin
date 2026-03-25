package checker

import "core:fmt"
import "core:mem"

import parser "mimir:parser"
import binder "mimir:binder"
import core   "mimir:core"

// ==================== Runtime Model Analysis (§21) ====================
//
// Post-inference analysis for runtime behavior patterns.
//
// Diagnostics:
//   RT001 — Reference cycle: self-referential assignment (child.parent = self)
//           suggests weakref to avoid GC pressure
//   RT002 — Object creation hotspot: constructor call inside loop body
//   RT003 — Unbounded collection growth in while-True loops
//   RT004 — Heavy import at module level (slow startup)
//   RT005 — Unreliable __del__ with side effects
//   RT006 — Mutable default argument accumulation

analyze_runtime_model :: proc(
	actx: ^Analysis_Pass_Context,
	diagnostics: ^[dynamic]core.Diagnostic,
) {
	module := actx.module
	bind_result := actx.bind_result
	file_path := actx.file_path
	allocator := actx.allocator
	// RT004: Heavy imports at module level
	check_heavy_imports(module, bind_result, file_path, diagnostics)

	// RT005: Unreliable __del__ with side effects
	check_unreliable_del(module.body, file_path, diagnostics)

	// RT006: Mutable default argument accumulation
	check_mutable_default_growth(module.body, file_path, diagnostics)

	// Walk each function and module-level body
	check_runtime_in_body(module.body, file_path, diagnostics, allocator)
	for stmt in module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			check_runtime_in_body(s.body, file_path, diagnostics, allocator)
		case ^parser.Async_Func_Def:
			check_runtime_in_body(s.body, file_path, diagnostics, allocator)
		case ^parser.Class_Def:
			for body_stmt in s.body {
				#partial switch ms in body_stmt {
				case ^parser.Func_Def:
					check_runtime_in_body(ms.body, file_path, diagnostics, allocator)
				case ^parser.Async_Func_Def:
					check_runtime_in_body(ms.body, file_path, diagnostics, allocator)
				}
			}
		}
	}
}

check_runtime_in_body :: proc(
	stmts: []parser.Stmt,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	for stmt in stmts {
		#partial switch s in stmt {
		// RT001: Reference cycle detection
		// Pattern: self.child.parent = self  OR  obj.ref = obj
		case ^parser.Assign:
			if len(s.targets) == 1 {
				check_ref_cycle(s.targets[0], s.value, s.loc, file_path, diagnostics)
			}

		// RT002: Object creation hotspot — constructor in loop
		case ^parser.For_Stmt:
			check_alloc_in_loop(s.body, file_path, diagnostics)
			check_runtime_in_body(s.body, file_path, diagnostics, allocator)
		case ^parser.Async_For:
			check_alloc_in_loop(s.body, file_path, diagnostics)
			check_runtime_in_body(s.body, file_path, diagnostics, allocator)
		case ^parser.While_Stmt:
			check_alloc_in_loop(s.body, file_path, diagnostics)
			// RT003: unbounded growth in while-True loops
			if _is_while_true(s) {
				check_unbounded_growth(s.body, file_path, diagnostics)
			}
			check_runtime_in_body(s.body, file_path, diagnostics, allocator)

		case ^parser.If_Stmt:
			check_runtime_in_body(s.body, file_path, diagnostics, allocator)
			check_runtime_in_body(s.orelse, file_path, diagnostics, allocator)
		}
	}
}

// RT001: Detect self-referential assignment patterns.
// Pattern 1: x.attr = x (direct)
// Pattern 2: self.child.parent = self (in method)
check_ref_cycle :: proc(
	target: parser.Expr,
	value: parser.Expr,
	loc: parser.Src_Loc,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
) {
	if target == nil || value == nil { return }

	// Value must be a Name_Expr
	val_name, val_ok := value.(^parser.Name_Expr)
	if !val_ok { return }

	// Target must be an Attribute_Expr whose root is the same name
	attr, attr_ok := target.(^parser.Attribute_Expr)
	if !attr_ok { return }

	root_name := _attr_root_name(attr)
	if len(root_name) == 0 { return }

	// Pattern 1: x.attr = x (self-referential)
	// Pattern 2: obj.parent = self (cross-object cycle in method)
	is_cycle := false
	if root_name == val_name.id {
		is_cycle = true
	} else if val_name.id == "self" {
		// Inside a method, assigning self to another object's attribute creates a cycle
		is_cycle = true
	}

	if is_cycle {
		append(diagnostics, core.Diagnostic{
			severity = .Info,
			location = core.Location{
				file   = file_path,
				line   = int(loc.line),
				column = int(loc.col),
			},
			code = "RT001",
			what = fmt.tprintf("potential reference cycle: '%s' assigned to '%s'", val_name.id, _expr_to_str(target)),
			why  = "circular references prevent reference counting from freeing objects, requiring garbage collection cycles",
			fix  = "use weakref.ref() for back-references to avoid cycles",
		})
	}
}

// Get the root Name_Expr.id from a chain of Attribute_Expr.
// e.g., self.child.parent → "self"
_attr_root_name :: proc(attr: ^parser.Attribute_Expr) -> string {
	#partial switch v in attr.value {
	case ^parser.Name_Expr:
		return v.id
	case ^parser.Attribute_Expr:
		return _attr_root_name(v)
	}
	return ""
}

// RT002: Detect constructor calls in loop bodies.
// Pattern: for x in items: handler = ClassName(...)
check_alloc_in_loop :: proc(
	stmts: []parser.Stmt,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Assign:
			if s.value != nil {
				if _is_constructor_call(s.value) {
					append(diagnostics, core.Diagnostic{
						severity = .Info,
						location = core.Location{
							file   = file_path,
							line   = int(s.loc.line),
							column = int(s.loc.col),
						},
						code = "RT002",
						what = "object construction inside loop",
						why  = "creating objects per iteration increases GC pressure; consider reusing or pre-allocating",
						fix  = "move construction outside the loop if the object can be reused",
					})
				}
			}
		case ^parser.If_Stmt:
			check_alloc_in_loop(s.body, file_path, diagnostics)
			check_alloc_in_loop(s.orelse, file_path, diagnostics)
		}
	}
}

// Simple expression-to-string for diagnostic messages.
_expr_to_str :: proc(expr: parser.Expr) -> string {
	if expr == nil { return "?" }
	#partial switch e in expr {
	case ^parser.Name_Expr: return e.id
	case ^parser.Attribute_Expr:
		base := _expr_to_str(e.value)
		return fmt.tprintf("%s.%s", base, e.attr)
	}
	return "?"
}

// Check if an expression is a constructor call (ClassName(...) where name starts uppercase).
_is_constructor_call :: proc(expr: parser.Expr) -> bool {
	call, ok := expr.(^parser.Call_Expr)
	if !ok { return false }
	name, name_ok := call.func.(^parser.Name_Expr)
	if !name_ok { return false }
	if len(name.id) == 0 { return false }
	// Heuristic: class names start with uppercase
	return name.id[0] >= 'A' && name.id[0] <= 'Z'
}

// ==================== RT003: Unbounded Collection Growth (§21.1) ====================

// Check if a While_Stmt is `while True:` (infinite loop)
_is_while_true :: proc(s: ^parser.While_Stmt) -> bool {
	if s.test == nil { return false }
	if name, ok := s.test.(^parser.Name_Expr); ok {
		return name.id == "True"
	}
	if c, ok := s.test.(^parser.Constant_Expr); ok {
		if bval, bok := c.value.(bool); bok {
			return bval
		}
	}
	return false
}

GROWTH_METHODS :: [?]string{"append", "extend", "add", "insert"}
SHRINK_METHODS :: [?]string{"clear", "pop", "remove", "popleft"}

// Check for container.append/extend/add without balancing clear/pop in while-True body
check_unbounded_growth :: proc(
	stmts: []parser.Stmt,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
) {
	// Collect containers that grow and containers that shrink
	growers := make(map[string]parser.Src_Loc, 4, context.temp_allocator)
	shrinkers := make(map[string]bool, 4, context.temp_allocator)
	has_break := false

	_scan_growth(stmts, &growers, &shrinkers, &has_break)

	// If loop has a break, growth may be bounded
	if has_break { return }

	// Flag growers without corresponding shrinkers
	for name, loc in growers {
		if name in shrinkers { continue }
		append(diagnostics, core.Diagnostic{
			severity = .Info,
			location = core.Location{
				file   = file_path,
				line   = int(loc.line),
				column = int(loc.col),
			},
			code = "RT003",
			what = fmt.tprintf("unbounded growth: '%s' grows in infinite loop without clearing", name),
			why  = "appending to a collection in a while-True loop without clearing causes unbounded memory growth",
			fix  = "add a size check with break, periodically clear the collection, or use a bounded deque",
		})
	}
}

_scan_growth :: proc(
	stmts: []parser.Stmt,
	growers: ^map[string]parser.Src_Loc,
	shrinkers: ^map[string]bool,
	has_break: ^bool,
) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Break_Stmt:
			has_break^ = true
		case ^parser.Expr_Stmt:
			if call, ok := s.value.(^parser.Call_Expr); ok {
				if attr, aok := call.func.(^parser.Attribute_Expr); aok {
					if recv, nok := attr.value.(^parser.Name_Expr); nok {
						for m in GROWTH_METHODS {
							if attr.attr == m {
								if recv.id not_in growers {
									growers[recv.id] = s.loc
								}
							}
						}
						for m in SHRINK_METHODS {
							if attr.attr == m {
								shrinkers[recv.id] = true
							}
						}
					}
				}
			}
		case ^parser.If_Stmt:
			_scan_growth(s.body, growers, shrinkers, has_break)
			_scan_growth(s.orelse, growers, shrinkers, has_break)
		case ^parser.Try_Stmt:
			_scan_growth(s.body, growers, shrinkers, has_break)
			for h in s.handlers { _scan_growth(h.body, growers, shrinkers, has_break) }
		}
	}
}

// ==================== RT004: Heavy Import (§21.4) ====================

Heavy_Import :: struct {
	module: string,
	time:   string,
}

HEAVY_IMPORTS :: [?]Heavy_Import{
	{"tensorflow",   "~8s"},
	{"torch",        "~4s"},
	{"pandas",       "~2s"},
	{"scipy",        "~3s"},
	{"matplotlib",   "~2s"},
	{"sklearn",      "~3s"},
	{"transformers", "~5s"},
	{"cv2",          "~2s"},
	{"sympy",        "~3s"},
	{"plotly",       "~2s"},
	{"dask",         "~2s"},
	{"pyspark",      "~4s"},
	{"numba",        "~3s"},
	{"jax",          "~3s"},
}

// Check module-level imports for known-heavy modules
check_heavy_imports :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
) {
	for stmt in module.body {
		#partial switch s in stmt {
		case ^parser.Import_Stmt:
			for alias in s.names {
				_check_import_weight(alias.name, s.loc, file_path, diagnostics)
			}
		case ^parser.Import_From:
			if s.level == 0 && len(s.module) > 0 {
				_check_import_weight(s.module, s.loc, file_path, diagnostics)
			}
		}
	}
}

_check_import_weight :: proc(
	module_name: string,
	loc: parser.Src_Loc,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
) {
	// Match module name or top-level prefix (e.g., "tensorflow.keras" matches "tensorflow")
	for hi in HEAVY_IMPORTS {
		if module_name == hi.module || _has_prefix_dot(module_name, hi.module) {
			append(diagnostics, core.Diagnostic{
				severity = .Info,
				location = core.Location{
					file   = file_path,
					line   = int(loc.line),
					column = int(loc.col),
				},
				code = "RT004",
				what = fmt.tprintf("heavy import: '%s' takes %s to import", module_name, hi.time),
				why  = "slow imports increase application startup time",
				fix  = "use lazy import: move inside function, or guard with `if TYPE_CHECKING:`",
			})
			return
		}
	}
}

// Check if name starts with prefix followed by '.'
_has_prefix_dot :: proc(name: string, prefix: string) -> bool {
	if len(name) <= len(prefix) { return false }
	if name[:len(prefix)] != prefix { return false }
	return name[len(prefix)] == '.'
}

// ==================== RT005: Unreliable __del__ (§21.2) ====================
//
// __del__ is called at an unpredictable time (or never). Side effects in
// __del__ (file I/O, network, logging) are unreliable. Suggest context
// managers or explicit close() instead.

DANGEROUS_DEL_CALLS :: [?]string{
	"close", "write", "flush", "send", "commit", "rollback",
	"shutdown", "disconnect", "release", "unlink", "remove",
	"save", "log", "print",
}

check_unreliable_del :: proc(
	stmts: []parser.Stmt,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Class_Def:
			for body_stmt in s.body {
				#partial switch ms in body_stmt {
				case ^parser.Func_Def:
					if ms.name == "__del__" {
						// Scan __del__ body for side-effect calls
						if _has_side_effect_calls(ms.body) {
							append(diagnostics, core.Diagnostic{
								severity = .Info,
								location = core.Location{
									file   = file_path,
									line   = int(ms.loc.line),
									column = int(ms.loc.col),
								},
								code = "RT005",
								what = fmt.tprintf("__del__ in class '%s' contains side-effect calls", s.name),
								why  = "__del__ is called at an unpredictable time (or never if there are reference cycles); side effects may silently fail",
								fix  = "use a context manager (__enter__/__exit__) or explicit close() method instead",
							})
						}
					}
				}
			}
		}
	}
}

_has_side_effect_calls :: proc(stmts: []parser.Stmt) -> bool {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Expr_Stmt:
			if _is_side_effect_call(s.value) { return true }
		case ^parser.If_Stmt:
			if _has_side_effect_calls(s.body) { return true }
			if _has_side_effect_calls(s.orelse) { return true }
		case ^parser.Try_Stmt:
			if _has_side_effect_calls(s.body) { return true }
			for h in s.handlers {
				if _has_side_effect_calls(h.body) { return true }
			}
		}
	}
	return false
}

_is_side_effect_call :: proc(expr: parser.Expr) -> bool {
	if expr == nil { return false }
	call, ok := expr.(^parser.Call_Expr)
	if !ok { return false }

	// Check for method calls: self.file.close(), self.conn.send(), etc.
	if attr, aok := call.func.(^parser.Attribute_Expr); aok {
		for name in DANGEROUS_DEL_CALLS {
			if attr.attr == name { return true }
		}
	}
	// Check for bare function calls: print(), logging.info(), etc.
	if name, nok := call.func.(^parser.Name_Expr); nok {
		for dname in DANGEROUS_DEL_CALLS {
			if name.id == dname { return true }
		}
	}
	return false
}

// ==================== RT006: Mutable Default Accumulation (§21.3) ====================
//
// def f(items=[]) creates a single list shared across ALL calls.
// If the function appends to it, memory grows unboundedly.

check_mutable_default_growth :: proc(
	stmts: []parser.Stmt,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			_check_func_mutable_default(s.name, s.args, s.body, s.loc, file_path, diagnostics)
		case ^parser.Async_Func_Def:
			_check_func_mutable_default(s.name, s.args, s.body, s.loc, file_path, diagnostics)
		case ^parser.Class_Def:
			for body_stmt in s.body {
				#partial switch ms in body_stmt {
				case ^parser.Func_Def:
					_check_func_mutable_default(ms.name, ms.args, ms.body, ms.loc, file_path, diagnostics)
				}
			}
		}
	}
}

_check_func_mutable_default :: proc(
	func_name: string,
	args: parser.Arguments,
	body: []parser.Stmt,
	loc: parser.Src_Loc,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
) {
	// Find params with mutable defaults ([], {}, set())
	mutable_params := make([dynamic]string, 0, 4, context.temp_allocator)
	n_params := len(args.posonlyargs) + len(args.args)
	n_defaults := len(args.defaults)
	for di := 0; di < n_defaults; di += 1 {
		d := args.defaults[di]
		if _is_mutable_default(d) {
			param_idx := di + (n_params - n_defaults)
			param_name := ""
			if param_idx < len(args.posonlyargs) {
				param_name = args.posonlyargs[param_idx].arg
			} else {
				idx := param_idx - len(args.posonlyargs)
				if idx < len(args.args) {
					param_name = args.args[idx].arg
				}
			}
			if len(param_name) > 0 {
				append(&mutable_params, param_name)
			}
		}
	}

	if len(mutable_params) == 0 { return }

	// Check if any mutable default param is mutated in body (append, extend, add, update, etc.)
	for param in mutable_params {
		if _param_is_mutated(param, body) {
			append(diagnostics, core.Diagnostic{
				severity = .Warning,
				location = core.Location{
					file   = file_path,
					line   = int(loc.line),
					column = int(loc.col),
				},
				code = "RT006",
				what = fmt.tprintf("mutable default '%s' in '%s' is mutated — shared across all calls", param, func_name),
				why  = "mutable default arguments are created once and shared across all function calls, causing silent accumulation",
				fix  = "use None as default and create inside the function: `if items is None: items = []`",
			})
		}
	}
}

_is_mutable_default :: proc(expr: parser.Expr) -> bool {
	if expr == nil { return false }
	#partial switch e in expr {
	case ^parser.List_Expr: return true  // []
	case ^parser.Dict_Expr: return true  // {}
	case ^parser.Set_Expr:  return true  // {x}
	case ^parser.Call_Expr:
		// set(), list(), dict()
		if name, ok := e.func.(^parser.Name_Expr); ok {
			return name.id == "list" || name.id == "dict" || name.id == "set"
		}
	}
	return false
}

MUTATION_METHODS :: [?]string{
	"append", "extend", "add", "insert", "update",
	"pop", "remove", "clear", "sort", "reverse",
	"__setitem__",
}

_param_is_mutated :: proc(param_name: string, stmts: []parser.Stmt) -> bool {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Expr_Stmt:
			if call, ok := s.value.(^parser.Call_Expr); ok {
				if attr, aok := call.func.(^parser.Attribute_Expr); aok {
					if recv, nok := attr.value.(^parser.Name_Expr); nok {
						if recv.id == param_name {
							for m in MUTATION_METHODS {
								if attr.attr == m { return true }
							}
						}
					}
				}
			}
		case ^parser.Assign:
			// param[key] = value
			for target in s.targets {
				if sub, ok := target.(^parser.Subscript_Expr); ok {
					if name, nok := sub.value.(^parser.Name_Expr); nok {
						if name.id == param_name { return true }
					}
				}
			}
		case ^parser.If_Stmt:
			if _param_is_mutated(param_name, s.body) { return true }
			if _param_is_mutated(param_name, s.orelse) { return true }
		case ^parser.For_Stmt:
			if _param_is_mutated(param_name, s.body) { return true }
		}
	}
	return false
}
