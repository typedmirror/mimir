package wasm

import "core:mem"
import "core:fmt"

import parser "mimir:parser"
import binder "mimir:binder"
import core "mimir:core"

// WASM Subset Validation — 8 rules (WASM001-WASM008)
// Validates that @wasm functions use only WASM-compilable constructs.

WASM_Config :: struct {
	ignore:      []string,
	select_only: []string,
}

WASM_Restriction_Context :: struct {
	module:       ^parser.Module,
	bind_result:  ^binder.Bind_Result,
	type_ctx:     ^WASM_Type_Context,
	file_path:    string,
	config:       ^WASM_Config,
	diagnostics:  [dynamic]core.Diagnostic,
	wasm_funcs:   [dynamic]^parser.Func_Def,
	current_func: string,
	allocator:    mem.Allocator,
}

default_wasm_config :: proc() -> WASM_Config {
	return WASM_Config{}
}

is_wasm_rule_enabled :: proc(code: string, config: ^WASM_Config) -> bool {
	if len(config.select_only) > 0 {
		for s in config.select_only {
			if s == code { return true }
		}
		return false
	}
	for ig in config.ignore {
		if ig == code { return false }
	}
	return true
}

// Main entry: validate file for WASM subset compliance.
validate_file :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	type_ctx: ^WASM_Type_Context,
	file_path: string,
	config: ^WASM_Config,
	allocator: mem.Allocator,
) -> ([]core.Diagnostic, []^parser.Func_Def) {
	ctx := WASM_Restriction_Context{
		module      = module,
		bind_result = bind_result,
		type_ctx    = type_ctx,
		file_path   = file_path,
		config      = config,
		diagnostics = make([dynamic]core.Diagnostic, 0, 16, allocator),
		wasm_funcs  = make([dynamic]^parser.Func_Def, 0, 8, allocator),
		allocator   = allocator,
	}

	find_wasm_functions(&ctx)

	for func in ctx.wasm_funcs {
		validate_function(func, &ctx)
	}

	return ctx.diagnostics[:], ctx.wasm_funcs[:]
}

// Scan module for functions with @wasm decorator.
find_wasm_functions :: proc(ctx: ^WASM_Restriction_Context) {
	for stmt in ctx.module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			if has_wasm_decorator(s.decorator_list) {
				append(&ctx.wasm_funcs, s)
			}
		case ^parser.Async_Func_Def:
			if has_wasm_decorator(s.decorator_list) {
				add_wasm_diagnostic(ctx, s.loc, "WASM007",
					"Async function cannot be a @wasm function",
					"WASM modules are synchronous — no async runtime",
					"Remove 'async' keyword from @wasm function")
			}
		case ^parser.Class_Def:
			for body_stmt in s.body {
				#partial switch ms in body_stmt {
				case ^parser.Func_Def:
					if has_wasm_decorator(ms.decorator_list) {
						append(&ctx.wasm_funcs, ms)
					}
				}
			}
		}
	}
}

has_wasm_decorator :: proc(decorators: []parser.Expr) -> bool {
	for d in decorators {
		#partial switch e in d {
		case ^parser.Name_Expr:
			if e.id == "wasm" { return true }
		}
	}
	return false
}

// Validate a single @wasm function.
validate_function :: proc(func: ^parser.Func_Def, ctx: ^WASM_Restriction_Context) {
	ctx.current_func = func.name

	// WASM001: Check parameter types
	if is_wasm_rule_enabled("WASM001", ctx.config) {
		check_params(func, ctx)
	}

	check_body(func.body, ctx)
}

// WASM001: Untyped parameter
check_params :: proc(func: ^parser.Func_Def, ctx: ^WASM_Restriction_Context) {
	for arg in func.args.args {
		if arg.annotation == nil {
			add_wasm_diagnostic(ctx, arg.loc, "WASM001",
				fmt.tprintf("Untyped parameter '%s' in @wasm function '%s'",
					arg.arg, func.name),
				"WASM requires static types for all locals",
				"Add a type annotation (int, float, bytes, Tensor[float32, ...])")
		}
	}
}

// Recursively validate statements.
check_body :: proc(stmts: []parser.Stmt, ctx: ^WASM_Restriction_Context) {
	for stmt in stmts {
		check_stmt(stmt, ctx)
	}
}

check_stmt :: proc(stmt: parser.Stmt, ctx: ^WASM_Restriction_Context) {
	#partial switch s in stmt {
	// WASM004: Exception handling
	case ^parser.Try_Stmt:
		if is_wasm_rule_enabled("WASM004", ctx.config) {
			add_wasm_diagnostic(ctx, s.loc, "WASM004",
				"Exception handling in @wasm function",
				"WASM MVP has no exception mechanism",
				"Move error handling outside the @wasm function")
		}
	case ^parser.Try_Star:
		if is_wasm_rule_enabled("WASM004", ctx.config) {
			add_wasm_diagnostic(ctx, s.loc, "WASM004",
				"Exception handling in @wasm function",
				"WASM MVP has no exception mechanism",
				"Move error handling outside the @wasm function")
		}
	case ^parser.Raise_Stmt:
		if is_wasm_rule_enabled("WASM004", ctx.config) {
			add_wasm_diagnostic(ctx, s.loc, "WASM004",
				"'raise' in @wasm function",
				"WASM cannot raise exceptions",
				"Use return values to signal errors")
		}
	case ^parser.Assert_Stmt:
		if is_wasm_rule_enabled("WASM004", ctx.config) {
			add_wasm_diagnostic(ctx, s.loc, "WASM004",
				"'assert' in @wasm function",
				"WASM cannot raise AssertionError",
				"Use conditional return instead of assert")
		}

	// WASM007: Unsupported constructs
	case ^parser.Global_Stmt:
		if is_wasm_rule_enabled("WASM007", ctx.config) {
			add_wasm_diagnostic(ctx, s.loc, "WASM007",
				"'global' statement in @wasm function",
				"WASM functions cannot access global mutable state",
				"Pass values as function parameters instead")
		}
	case ^parser.Nonlocal_Stmt:
		if is_wasm_rule_enabled("WASM007", ctx.config) {
			add_wasm_diagnostic(ctx, s.loc, "WASM007",
				"'nonlocal' statement in @wasm function",
				"WASM functions cannot access closure variables",
				"Pass values as function parameters instead")
		}
	case ^parser.With_Stmt:
		if is_wasm_rule_enabled("WASM007", ctx.config) {
			add_wasm_diagnostic(ctx, s.loc, "WASM007",
				"'with' statement in @wasm function",
				"Context managers require heap allocation",
				"Manage resources outside the @wasm function")
		}
	case ^parser.Async_With:
		if is_wasm_rule_enabled("WASM007", ctx.config) {
			add_wasm_diagnostic(ctx, s.loc, "WASM007",
				"'async with' in @wasm function",
				"Async constructs are not WASM-compatible",
				"Remove async constructs from @wasm function")
		}
	case ^parser.Class_Def:
		if is_wasm_rule_enabled("WASM007", ctx.config) {
			add_wasm_diagnostic(ctx, s.loc, "WASM007",
				"Class definition inside @wasm function",
				"WASM cannot define classes — no heap allocation",
				"Define classes outside the @wasm function")
		}
	case ^parser.Func_Def:
		if is_wasm_rule_enabled("WASM007", ctx.config) {
			add_wasm_diagnostic(ctx, s.loc, "WASM007",
				"Nested function definition inside @wasm function",
				"WASM cannot define nested functions — no closures",
				"Define helper functions at module level with @wasm decorator")
		}

	// WASM008: Potentially unbounded while loop
	case ^parser.While_Stmt:
		if is_wasm_rule_enabled("WASM008", ctx.config) {
			if is_unbounded_while(s) {
				add_wasm_diagnostic(ctx, s.loc, "WASM008",
					"Potentially unbounded 'while' loop in @wasm function",
					"May not terminate in browser context",
					"Add a provable termination condition or use 'for' with a known range")
			}
		}
		check_body(s.body, ctx)
		check_body(s.orelse, ctx)

	// Recurse into control flow
	case ^parser.For_Stmt:
		check_body(s.body, ctx)
		check_body(s.orelse, ctx)
		check_expr(s.iter, ctx)
	case ^parser.If_Stmt:
		check_body(s.body, ctx)
		check_body(s.orelse, ctx)
		check_expr(s.test, ctx)

	// Check expressions in statements
	case ^parser.Assign:
		check_expr(s.value, ctx)
		for t in s.targets {
			check_expr(t, ctx)
		}
	case ^parser.Ann_Assign:
		if s.value != nil { check_expr(s.value, ctx) }
	case ^parser.Aug_Assign:
		check_expr(s.value, ctx)
	case ^parser.Return_Stmt:
		if s.value != nil { check_expr(s.value, ctx) }
	case ^parser.Expr_Stmt:
		check_expr(s.value, ctx)
	}
}

// Check expressions for WASM-incompatible constructs.
check_expr :: proc(expr: parser.Expr, ctx: ^WASM_Restriction_Context) {
	if expr == nil { return }

	#partial switch e in expr {
	// WASM002: String operations
	case ^parser.Joined_Str:
		if is_wasm_rule_enabled("WASM002", ctx.config) {
			add_wasm_diagnostic(ctx, e.loc, "WASM002",
				"F-string in @wasm function",
				"No string heap in WASM linear memory",
				"Move string formatting outside the @wasm function")
		}

	// WASM003: Heap allocation
	case ^parser.List_Expr:
		if is_wasm_rule_enabled("WASM003", ctx.config) {
			add_wasm_diagnostic(ctx, e.loc, "WASM003",
				"List literal in @wasm function",
				"WASM has no GC — only linear memory",
				"Use Tensor types for collections of numeric data")
		}
	case ^parser.Dict_Expr:
		if is_wasm_rule_enabled("WASM003", ctx.config) {
			add_wasm_diagnostic(ctx, e.loc, "WASM003",
				"Dict literal in @wasm function",
				"WASM has no GC — only linear memory",
				"Use Tensor types or pass data as parameters")
		}
	case ^parser.Set_Expr:
		if is_wasm_rule_enabled("WASM003", ctx.config) {
			add_wasm_diagnostic(ctx, e.loc, "WASM003",
				"Set literal in @wasm function",
				"WASM has no GC — only linear memory",
				"Use Tensor types for numeric data")
		}
	case ^parser.List_Comp:
		if is_wasm_rule_enabled("WASM003", ctx.config) {
			add_wasm_diagnostic(ctx, e.loc, "WASM003",
				"List comprehension in @wasm function",
				"Comprehensions allocate heap memory",
				"Use explicit loops with Tensor indexing instead")
		}
	case ^parser.Set_Comp:
		if is_wasm_rule_enabled("WASM003", ctx.config) {
			add_wasm_diagnostic(ctx, e.loc, "WASM003",
				"Set comprehension in @wasm function",
				"Comprehensions allocate heap memory",
				"Use explicit loops instead")
		}
	case ^parser.Dict_Comp:
		if is_wasm_rule_enabled("WASM003", ctx.config) {
			add_wasm_diagnostic(ctx, e.loc, "WASM003",
				"Dict comprehension in @wasm function",
				"Comprehensions allocate heap memory",
				"Use explicit loops instead")
		}

	// WASM007: yield
	case ^parser.Yield_Expr:
		if is_wasm_rule_enabled("WASM007", ctx.config) {
			add_wasm_diagnostic(ctx, e.loc, "WASM007",
				"'yield' in @wasm function",
				"WASM functions cannot be generators",
				"Remove yield and return results directly")
		}
	case ^parser.Yield_From_Expr:
		if is_wasm_rule_enabled("WASM007", ctx.config) {
			add_wasm_diagnostic(ctx, e.loc, "WASM007",
				"'yield from' in @wasm function",
				"WASM functions cannot be generators",
				"Remove yield and return results directly")
		}

	// WASM002: String constants
	case ^parser.Constant_Expr:
		#partial switch _ in e.value {
		case string:
			if is_wasm_rule_enabled("WASM002", ctx.config) {
				add_wasm_diagnostic(ctx, e.loc, "WASM002",
					"String literal in @wasm function",
					"No string heap in WASM linear memory",
					"Move string processing outside the @wasm function")
			}
		}

	// WASM005/WASM006: Function calls
	case ^parser.Call_Expr:
		check_call_for_wasm(e, ctx)
		for arg in e.args {
			check_expr(arg, ctx)
		}

	// Recurse into subexpressions
	case ^parser.Bin_Op_Expr:
		check_expr(e.left, ctx)
		check_expr(e.right, ctx)
	case ^parser.Unary_Op_Expr:
		check_expr(e.operand, ctx)
	case ^parser.Compare_Expr:
		check_expr(e.left, ctx)
		for comp in e.comparators {
			check_expr(comp, ctx)
		}
	case ^parser.If_Expr:
		check_expr(e.test, ctx)
		check_expr(e.body, ctx)
		check_expr(e.orelse, ctx)
	case ^parser.Subscript_Expr:
		check_expr(e.value, ctx)
		check_expr(e.slice, ctx)
	case ^parser.Attribute_Expr:
		check_expr(e.value, ctx)
	case ^parser.Tuple_Expr:
		for elt in e.elts {
			check_expr(elt, ctx)
		}
	case ^parser.Starred_Expr:
		if is_wasm_rule_enabled("WASM003", ctx.config) {
			add_wasm_diagnostic(ctx, e.loc, "WASM003",
				"Star expression (*args) in @wasm function",
				"Variable-length arguments require heap allocation",
				"Use fixed parameter lists instead")
		}
	}
}

// WASM005/WASM006: Check function calls.
check_call_for_wasm :: proc(call: ^parser.Call_Expr, ctx: ^WASM_Restriction_Context) {
	#partial switch f in call.func {
	case ^parser.Name_Expr:
		// WASM005: Recursion (warning)
		if is_wasm_rule_enabled("WASM005", ctx.config) {
			if f.id == ctx.current_func {
				add_wasm_diagnostic_severity(ctx, call.loc, "WASM005", .Warning,
					fmt.tprintf("Recursive call to @wasm function '%s'", f.id),
					"WASM stack is ~1MB — deep recursion will trap",
					"Consider rewriting with iteration")
			}
		}
		// WASM006: Dynamic dispatch
		if is_wasm_rule_enabled("WASM006", ctx.config) {
			DYNAMIC_DISPATCH :: [?]string{"getattr", "hasattr", "type", "isinstance", "issubclass", "eval", "exec", "compile"}
			for dd in DYNAMIC_DISPATCH {
				if f.id == dd {
					add_wasm_diagnostic(ctx, call.loc, "WASM006",
						fmt.tprintf("Dynamic dispatch function '%s()' in @wasm function", f.id),
						"No Python runtime in WASM",
						"Use static typing and compile-time type checks instead")
					break
				}
			}
		}
		// WASM002: String operations (print is exempt — supported via host import)
		if is_wasm_rule_enabled("WASM002", ctx.config) {
			if f.id == "str" || f.id == "format" || f.id == "repr" {
				add_wasm_diagnostic(ctx, call.loc, "WASM002",
					fmt.tprintf("String operation '%s()' in @wasm function", f.id),
					"No string heap in WASM linear memory",
					"Move string operations outside the @wasm function")
			}
		}
	case ^parser.Attribute_Expr:
		// WASM002: String method calls
		if is_wasm_rule_enabled("WASM002", ctx.config) {
			STR_METHODS :: [?]string{"format", "encode", "decode", "split", "join", "strip", "replace", "upper", "lower"}
			for m in STR_METHODS {
				if f.attr == m {
					add_wasm_diagnostic(ctx, call.loc, "WASM002",
						fmt.tprintf("String method '.%s()' in @wasm function", f.attr),
						"No string heap in WASM linear memory",
						"Move string processing outside the @wasm function")
					break
				}
			}
		}
	}
}

// Simple heuristic: `while True` is unbounded.
is_unbounded_while :: proc(w: ^parser.While_Stmt) -> bool {
	#partial switch e in w.test {
	case ^parser.Constant_Expr:
		#partial switch v in e.value {
		case bool:
			return v == true
		}
	case ^parser.Name_Expr:
		if e.id == "True" { return true }
	}
	return false
}

add_wasm_diagnostic :: proc(ctx: ^WASM_Restriction_Context, loc: parser.Src_Loc, code: string, what: string, why: string, fix: string) {
	add_wasm_diagnostic_severity(ctx, loc, code, .Error, what, why, fix)
}

add_wasm_diagnostic_severity :: proc(ctx: ^WASM_Restriction_Context, loc: parser.Src_Loc, code: string, severity: core.Severity, what: string, why: string, fix: string) {
	append(&ctx.diagnostics, core.Diagnostic{
		severity = severity,
		location = core.Location{
			file   = ctx.file_path,
			line   = int(loc.line),
			column = int(loc.col),
		},
		code = code,
		what = what,
		why  = why,
		fix  = fix,
	})
}
