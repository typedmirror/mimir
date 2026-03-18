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

analyze_runtime_model :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	// RT004: Heavy imports at module level
	check_heavy_imports(module, bind_result, file_path, diagnostics)

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
