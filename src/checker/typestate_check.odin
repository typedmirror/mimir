package checker

import "core:fmt"
import "core:mem"

import parser "mimir:parser"
import binder "mimir:binder"
import core   "mimir:core"

// ==================== Context Manager Typestate (§4.2) ====================
//
// Post-inference analysis: detect resource access after with-block exit.
// Walks statement lists, tracks which variables were bound in `with ... as var:`,
// then checks if subsequent statements in the same scope call resource methods
// (read, write, seek, etc.) on those variables.
//
// Diagnostic:
//   SAF010 — use after close: resource method called after with block exited

RESOURCE_METHODS :: [?]string{
	"read", "write", "readline", "readlines", "writelines",
	"seek", "tell", "flush", "fileno", "truncate",
	"send", "recv", "sendall", "close",
}

analyze_typestate :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	// Check module-level statements
	check_typestate_in_stmts(module.body, file_path, diagnostics)

	// Check each function body
	for stmt in module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			check_typestate_in_stmts(s.body, file_path, diagnostics)
		case ^parser.Async_Func_Def:
			check_typestate_in_stmts(s.body, file_path, diagnostics)
		case ^parser.Class_Def:
			for body_stmt in s.body {
				#partial switch ms in body_stmt {
				case ^parser.Func_Def:
					check_typestate_in_stmts(ms.body, file_path, diagnostics)
				case ^parser.Async_Func_Def:
					check_typestate_in_stmts(ms.body, file_path, diagnostics)
				}
			}
		}
	}
}

check_typestate_in_stmts :: proc(
	stmts: []parser.Stmt,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
) {
	closed_names := make(map[string]parser.Src_Loc, 4)
	defer delete(closed_names)

	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.With_Stmt:
			// After this with block, its `as` variables are closed
			for item in s.items {
				if item.optional_vars != nil {
					if name, ok := item.optional_vars.(^parser.Name_Expr); ok {
						closed_names[name.id] = s.loc
					}
				}
			}
		case ^parser.Async_With:
			for item in s.items {
				if item.optional_vars != nil {
					if name, ok := item.optional_vars.(^parser.Name_Expr); ok {
						closed_names[name.id] = s.loc
					}
				}
			}
		case ^parser.Expr_Stmt:
			// Check for closed variable access in expression statements
			check_expr_typestate(s.value, closed_names, file_path, diagnostics)
		case ^parser.Assign:
			check_expr_typestate(s.value, closed_names, file_path, diagnostics)
			// If the variable is reassigned (e.g., f = open(...)), un-close it
			if len(s.targets) == 1 {
				if name, ok := s.targets[0].(^parser.Name_Expr); ok {
					delete_key(&closed_names, name.id)
				}
			}
		}
	}
}

check_expr_typestate :: proc(
	expr: parser.Expr,
	closed_names: map[string]parser.Src_Loc,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
) {
	if expr == nil { return }
	#partial switch e in expr {
	case ^parser.Call_Expr:
		// Check if callee is a resource method on a closed variable
		if attr, ok := e.func.(^parser.Attribute_Expr); ok {
			if name, nok := attr.value.(^parser.Name_Expr); nok {
				if name.id in closed_names {
					for m in RESOURCE_METHODS {
						if attr.attr == m {
							append(diagnostics, core.Diagnostic{
								severity = .Error,
								location = core.Location{
									file   = file_path,
									line   = int(e.loc.line),
									column = int(e.loc.col),
								},
								code = "SAF010",
								what = fmt.tprintf("use after close: '%s.%s()' called after 'with' block exited", name.id, attr.attr),
								why  = "the resource was closed when the 'with' block ended — accessing it is a runtime error",
								fix  = fmt.tprintf("move '%s.%s()' inside the 'with' block, or re-open the resource", name.id, attr.attr),
							})
							return
						}
					}
				}
			}
		}
		// Recurse into call args
		for arg in e.args { check_expr_typestate(arg, closed_names, file_path, diagnostics) }
	}
}
