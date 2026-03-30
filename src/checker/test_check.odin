package checker

import "core:fmt"
import "core:mem"
import "core:strings"

import parser "mimir:parser"
import binder "mimir:binder"
import core   "mimir:core"

// ==================== Test Analysis (§31.2) ====================
//
// Post-inference analysis for mock and fixture patterns.
//
// Diagnostics:
//   TEST001 — Mock return_value type mismatch against spec class method
//   TEST002 — Fixture return type injected into test function parameter

// ==================== TEST002: Fixture Type Collection ====================

// Scan for @fixture / @pytest.fixture decorated functions → name → return type
collect_fixture_types :: proc(
	stmts: []parser.Stmt,
	bind_result: ^binder.Bind_Result,
	return_type_map: ^map[binder.Scope_ID]Type_ID,
) -> map[string]Type_ID {
	result := make(map[string]Type_ID, 8, context.temp_allocator)
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			if _has_fixture_decorator(s.decorator_list, bind_result) && s.returns != nil {
				// Find scope for this function
				scope_id := _find_func_scope(s.name, s.loc, bind_result)
				if scope_id != binder.INVALID_SCOPE {
					if ret_type, ok := return_type_map[scope_id]; ok {
						if ret_type != TYPE_UNKNOWN {
							result[s.name] = ret_type
						}
					}
				}
			}
		case ^parser.Class_Def:
			// Check methods in conftest-style classes
			for bs in s.body {
				#partial switch ms in bs {
				case ^parser.Func_Def:
					if _has_fixture_decorator(ms.decorator_list, bind_result) && ms.returns != nil {
						scope_id := _find_func_scope(ms.name, ms.loc, bind_result)
						if scope_id != binder.INVALID_SCOPE {
							if ret_type, ok := return_type_map[scope_id]; ok {
								if ret_type != TYPE_UNKNOWN {
									result[ms.name] = ret_type
								}
							}
						}
					}
				}
			}
		}
	}
	return result
}

_has_fixture_decorator :: proc(decorators: []parser.Expr, bind_result: ^binder.Bind_Result) -> bool {
	for dec in decorators {
		#partial switch d in dec {
		case ^parser.Name_Expr:
			if d.id == "fixture" { return true }
		case ^parser.Attribute_Expr:
			if d.attr == "fixture" { return true }
		case ^parser.Call_Expr:
			// @pytest.fixture() with parens
			if name, ok := d.func.(^parser.Name_Expr); ok {
				if name.id == "fixture" { return true }
			}
			if attr, ok := d.func.(^parser.Attribute_Expr); ok {
				if attr.attr == "fixture" { return true }
			}
		}
	}
	return false
}

_find_func_scope :: proc(name: string, loc: parser.Src_Loc, bind_result: ^binder.Bind_Result) -> binder.Scope_ID {
	for &scope in bind_result.scopes {
		if scope.name == name && scope.kind == .Function && scope.loc.line == loc.line {
			return scope.id
		}
	}
	return binder.INVALID_SCOPE
}

// Inject fixture return types into test function params that are unannotated
inject_fixture_types :: proc(
	scope: ^binder.Scope,
	bind_result: ^binder.Bind_Result,
	env: ^Type_Env,
	fixture_types: ^map[string]Type_ID,
) {
	for name, sym_id in scope.symbols {
		sym := binder.result_get_symbol(bind_result, sym_id)
		if sym == nil || .Is_Param not_in sym.flags { continue }
		// Only inject if param is currently UNKNOWN (no annotation)
		if t, ok := env.types[sym_id]; ok && t != TYPE_UNKNOWN { continue }
		// Check if param name matches a fixture
		if fixture_type, has := fixture_types[name]; has {
			env.types[sym_id] = fixture_type
		}
	}
}

// ==================== TEST001: Mock Spec Validation ====================

// Detect Mock(spec=ClassName), then check mock.method.return_value = X
analyze_test_patterns :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	reg: ^Type_Registry,
	expr_types: ^map[rawptr]Type_ID,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	// Check for unittest.mock import
	has_mock := false
	for &imp in bind_result.imports {
		if imp.module_name == "unittest.mock" || imp.module_name == "unittest" {
			has_mock = true
		}
	}
	if !has_mock { return }

	// Phase 1: Collect mock variables with spec classes
	// mock_db = Mock(spec=Database) → mock_vars["mock_db"] = Database_ClassType
	mock_vars := make(map[string]Type_ID, 4, allocator)
	_collect_mock_specs(module.body, bind_result, reg, &mock_vars, allocator)

	// Also scan function bodies
	for stmt in module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			_collect_mock_specs(s.body, bind_result, reg, &mock_vars, allocator)
		case ^parser.Async_Func_Def:
			_collect_mock_specs(s.body, bind_result, reg, &mock_vars, allocator)
		case ^parser.Class_Def:
			for bs in s.body {
				#partial switch ms in bs {
				case ^parser.Func_Def:
					_collect_mock_specs(ms.body, bind_result, reg, &mock_vars, allocator)
				}
			}
		}
	}

	if len(mock_vars) == 0 { return }

	// Phase 2: Check mock.method.return_value = X assignments
	_check_mock_return_values(module.body, mock_vars, reg, expr_types, file_path, diagnostics, allocator)
	for stmt in module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			_check_mock_return_values(s.body, mock_vars, reg, expr_types, file_path, diagnostics, allocator)
		case ^parser.Class_Def:
			for bs in s.body {
				#partial switch ms in bs {
				case ^parser.Func_Def:
					_check_mock_return_values(ms.body, mock_vars, reg, expr_types, file_path, diagnostics, allocator)
				}
			}
		}
	}
}

_collect_mock_specs :: proc(
	stmts: []parser.Stmt,
	bind_result: ^binder.Bind_Result,
	reg: ^Type_Registry,
	mock_vars: ^map[string]Type_ID,
	allocator: mem.Allocator,
) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Assign:
			if len(s.targets) != 1 { continue }
			name, is_name := s.targets[0].(^parser.Name_Expr)
			if !is_name { continue }
			call, is_call := s.value.(^parser.Call_Expr)
			if !is_call { continue }

			// Check if call is Mock(...) or MagicMock(...)
			func_name := ""
			if fn, ok := call.func.(^parser.Name_Expr); ok {
				func_name = fn.id
			}
			if func_name != "Mock" && func_name != "MagicMock" && func_name != "patch" { continue }

			// Find spec= keyword arg
			for kw in call.keywords {
				if kw.arg == "spec" || kw.arg == "spec_set" {
					// Resolve the spec class
					if spec_name, ok := kw.value.(^parser.Name_Expr); ok {
						if sym_id, rok := binder.get_ref(bind_result, rawptr(spec_name)); rok {
							if class_type, found := reg.class_types[qualify(reg, sym_id)]; found {
								mock_vars[name.id] = class_type
							}
						}
					}
					break
				}
			}
		case ^parser.If_Stmt:
			_collect_mock_specs(s.body, bind_result, reg, mock_vars, allocator)
			_collect_mock_specs(s.orelse, bind_result, reg, mock_vars, allocator)
		}
	}
}

_check_mock_return_values :: proc(
	stmts: []parser.Stmt,
	mock_vars: map[string]Type_ID,
	reg: ^Type_Registry,
	expr_types: ^map[rawptr]Type_ID,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Assign:
			if len(s.targets) != 1 { continue }
			// Pattern: mock_db.fetch.return_value = X
			attr, is_attr := s.targets[0].(^parser.Attribute_Expr)
			if !is_attr || attr.attr != "return_value" { continue }

			// attr.value should be mock_name.method_name
			method_attr, is_method := attr.value.(^parser.Attribute_Expr)
			if !is_method { continue }

			mock_name_expr, is_mock_name := method_attr.value.(^parser.Name_Expr)
			if !is_mock_name { continue }

			class_type_id, has_mock := mock_vars[mock_name_expr.id]
			if !has_mock { continue }

			method_name := method_attr.attr

			// Look up method's return type in the spec class
			ct := get_type(reg, class_type_id)
			#partial switch cls in ct.info {
			case Class_Type:
				if method_type_id, found := cls.attrs[method_name]; found {
					mt := get_type(reg, method_type_id)
					#partial switch callable in mt.info {
					case Callable_Type:
						expected_return := callable.return_type
						if expected_return == TYPE_UNKNOWN || expected_return == TYPE_ANY { continue }

						// Get the assigned value's type
						actual_type := TYPE_UNKNOWN
						if t, ok := expr_types[expr_to_rawptr(s.value)]; ok {
							actual_type = t
						}
						if actual_type == TYPE_UNKNOWN || actual_type == TYPE_ANY { continue }

						if !is_assignable(reg, actual_type, expected_return) {
							append(diagnostics, core.Diagnostic{
								severity = .Warning,
								location = core.Location{
									file   = file_path,
									line   = int(s.loc.line),
									column = int(s.loc.col),
								},
								code = "TEST001",
								what = fmt.tprintf("mock return_value type mismatch: '%s.%s' returns '%s', got '%s'",
									mock_name_expr.id, method_name,
									type_to_string(reg, expected_return),
									type_to_string(reg, actual_type)),
								why  = "mock return_value should match the spec class method's return type for accurate testing",
								fix  = fmt.tprintf("change return_value to a '%s' value", type_to_string(reg, expected_return)),
							})
						}
					}
				}
			}
		case ^parser.If_Stmt:
			_check_mock_return_values(s.body, mock_vars, reg, expr_types, file_path, diagnostics, allocator)
			_check_mock_return_values(s.orelse, mock_vars, reg, expr_types, file_path, diagnostics, allocator)
		}
	}
}
