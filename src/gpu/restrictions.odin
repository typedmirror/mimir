package gpu

import "core:mem"

import parser "mimir:parser"
import binder "mimir:binder"
import core "mimir:core"

// GPU Subset Validation — 10 rules (GPU001-GPU010)
// Validates that @gpu functions use only GPU-compatible constructs.

GPU_Config :: struct {
	ignore:      []string,
	select_only: []string,
}

GPU_Restriction_Context :: struct {
	module:       ^parser.Module,
	bind_result:  ^binder.Bind_Result,
	type_ctx:     ^GPU_Type_Context,
	file_path:    string,
	config:       ^GPU_Config,
	diagnostics:  [dynamic]core.Diagnostic,
	gpu_funcs:    [dynamic]^parser.Func_Def,
	current_func: string, // name of @gpu function being validated
	allocator:    mem.Allocator,
}

default_gpu_config :: proc() -> GPU_Config {
	return GPU_Config{}
}

is_gpu_rule_enabled :: proc(code: string, config: ^GPU_Config) -> bool {
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

// Main entry point: validate a file for GPU subset compliance.
// Returns diagnostics and list of @gpu functions found.
validate_file :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	type_ctx: ^GPU_Type_Context,
	file_path: string,
	config: ^GPU_Config,
	allocator: mem.Allocator,
) -> ([]core.Diagnostic, []^parser.Func_Def) {
	ctx := GPU_Restriction_Context{
		module      = module,
		bind_result = bind_result,
		type_ctx    = type_ctx,
		file_path   = file_path,
		config      = config,
		diagnostics = make([dynamic]core.Diagnostic, 0, 16, allocator),
		gpu_funcs   = make([dynamic]^parser.Func_Def, 0, 8, allocator),
		allocator   = allocator,
	}

	// Discover @gpu functions
	find_gpu_functions(&ctx)

	// Validate each @gpu function
	for func in ctx.gpu_funcs {
		validate_function(func, &ctx)
	}

	return ctx.diagnostics[:], ctx.gpu_funcs[:]
}

// Scan module for functions with @gpu decorator.
find_gpu_functions :: proc(ctx: ^GPU_Restriction_Context) {
	for stmt in ctx.module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			if has_gpu_decorator(s.decorator_list) {
				append(&ctx.gpu_funcs, s)
			}
		case ^parser.Async_Func_Def:
			// Async @gpu doesn't make sense but detect for error
			if has_gpu_decorator(s.decorator_list) {
				add_gpu_diagnostic(ctx, s.loc, "GPU010",
					"Async function cannot be a @gpu kernel",
					"GPU kernels are synchronous compute dispatches",
					"Remove 'async' keyword from @gpu function")
			}
		case ^parser.Class_Def:
			// Scan methods inside classes
			for body_stmt in s.body {
				#partial switch ms in body_stmt {
				case ^parser.Func_Def:
					if has_gpu_decorator(ms.decorator_list) {
						append(&ctx.gpu_funcs, ms)
					}
				}
			}
		}
	}
}

has_gpu_decorator :: proc(decorators: []parser.Expr) -> bool {
	for d in decorators {
		#partial switch e in d {
		case ^parser.Name_Expr:
			if e.id == "gpu" { return true }
		}
	}
	return false
}

// Validate a single @gpu function against all rules.
validate_function :: proc(func: ^parser.Func_Def, ctx: ^GPU_Restriction_Context) {
	ctx.current_func = func.name

	// GPU001: Check parameter types
	if is_gpu_rule_enabled("GPU001", ctx.config) {
		check_params(func, ctx)
	}

	// Check body against all rules
	check_body(func.body, ctx)
}

// GPU001: Non-numeric type in @gpu params
check_params :: proc(func: ^parser.Func_Def, ctx: ^GPU_Restriction_Context) {
	for arg in func.args.args {
		if arg.annotation == nil { continue }
		// Check if annotation resolves to a GPU type
		tid := resolve_gpu_annotation(arg.annotation, ctx.type_ctx)
		if tid == 0 { // INVALID_TYPE
			// Check if it's a known non-GPU type name
			#partial switch e in arg.annotation {
			case ^parser.Name_Expr:
				if is_non_gpu_type(e.id) {
					add_gpu_diagnostic(ctx, arg.loc, "GPU001",
						fmt.tprintf("Non-numeric type '%s' in @gpu function parameter '%s'",
							e.id, arg.arg),
						"GPU compute operates on numeric data only",
						"Use Tensor[float32, ...] or other GPU-compatible numeric types")
				}
			}
		}
	}
}

import "core:fmt"

// Check if a type name is a known non-GPU type.
is_non_gpu_type :: proc(name: string) -> bool {
	NON_GPU_TYPES :: [?]string{"str", "bytes", "list", "dict", "set", "tuple", "object", "type"}
	for t in NON_GPU_TYPES {
		if name == t { return true }
	}
	return false
}

// Recursively validate statements in @gpu function body.
check_body :: proc(stmts: []parser.Stmt, ctx: ^GPU_Restriction_Context) {
	for stmt in stmts {
		check_stmt(stmt, ctx)
	}
}

check_stmt :: proc(stmt: parser.Stmt, ctx: ^GPU_Restriction_Context) {
	#partial switch s in stmt {
	// GPU004: Exception handling
	case ^parser.Try_Stmt:
		if is_gpu_rule_enabled("GPU004", ctx.config) {
			add_gpu_diagnostic(ctx, s.loc, "GPU004",
				"Exception handling in @gpu function",
				"GPU kernels cannot handle exceptions — there is no call stack to unwind",
				"Move error handling outside the @gpu function")
		}
	case ^parser.Try_Star:
		if is_gpu_rule_enabled("GPU004", ctx.config) {
			add_gpu_diagnostic(ctx, s.loc, "GPU004",
				"Exception handling in @gpu function",
				"GPU kernels cannot handle exceptions — there is no call stack to unwind",
				"Move error handling outside the @gpu function")
		}
	case ^parser.Raise_Stmt:
		if is_gpu_rule_enabled("GPU004", ctx.config) {
			add_gpu_diagnostic(ctx, s.loc, "GPU004",
				"'raise' in @gpu function",
				"GPU kernels cannot raise exceptions",
				"Use return values to signal errors")
		}
	case ^parser.Assert_Stmt:
		if is_gpu_rule_enabled("GPU004", ctx.config) {
			add_gpu_diagnostic(ctx, s.loc, "GPU004",
				"'assert' in @gpu function",
				"GPU kernels cannot raise AssertionError",
				"Use conditional return instead of assert")
		}

	// GPU010: Unsupported syntax
	case ^parser.Global_Stmt:
		if is_gpu_rule_enabled("GPU010", ctx.config) {
			add_gpu_diagnostic(ctx, s.loc, "GPU010",
				"'global' statement in @gpu function",
				"GPU kernels cannot access global mutable state",
				"Pass values as function parameters instead")
		}
	case ^parser.Nonlocal_Stmt:
		if is_gpu_rule_enabled("GPU010", ctx.config) {
			add_gpu_diagnostic(ctx, s.loc, "GPU010",
				"'nonlocal' statement in @gpu function",
				"GPU kernels cannot access closure variables",
				"Pass values as function parameters instead")
		}
	case ^parser.With_Stmt:
		if is_gpu_rule_enabled("GPU010", ctx.config) {
			add_gpu_diagnostic(ctx, s.loc, "GPU010",
				"'with' statement in @gpu function",
				"Context managers require heap allocation and are not GPU-compatible",
				"Manage resources outside the @gpu function")
		}
	case ^parser.Async_With:
		if is_gpu_rule_enabled("GPU010", ctx.config) {
			add_gpu_diagnostic(ctx, s.loc, "GPU010",
				"'async with' in @gpu function",
				"Async constructs are not GPU-compatible",
				"Remove async constructs from @gpu function")
		}
	case ^parser.Class_Def:
		if is_gpu_rule_enabled("GPU010", ctx.config) {
			add_gpu_diagnostic(ctx, s.loc, "GPU010",
				"Class definition inside @gpu function",
				"GPU kernels cannot define classes — no heap allocation",
				"Define classes outside the @gpu function")
		}
	case ^parser.Func_Def:
		if is_gpu_rule_enabled("GPU010", ctx.config) {
			add_gpu_diagnostic(ctx, s.loc, "GPU010",
				"Nested function definition inside @gpu function",
				"GPU kernels cannot define nested functions — no closures",
				"Define helper functions at module level with @gpu decorator")
		}

	// GPU008: While loops need termination analysis
	case ^parser.While_Stmt:
		if is_gpu_rule_enabled("GPU008", ctx.config) {
			if is_unbounded_while(s) {
				add_gpu_diagnostic(ctx, s.loc, "GPU008",
					"Potentially unbounded 'while' loop in @gpu function",
					"GPU kernels require bounded iteration to prevent device hangs",
					"Use a 'for' loop with a known range, or add a provable termination condition")
			}
		}
		check_body(s.body, ctx)
		check_body(s.orelse, ctx)

	// Recurse into control flow
	case ^parser.For_Stmt:
		check_body(s.body, ctx)
		check_body(s.orelse, ctx)
		check_expr(s.iter, ctx) // check for non-GPU iterables
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

// Check expressions for GPU-incompatible constructs.
check_expr :: proc(expr: parser.Expr, ctx: ^GPU_Restriction_Context) {
	if expr == nil { return }

	#partial switch e in expr {
	// GPU002: String operations
	case ^parser.Joined_Str:
		if is_gpu_rule_enabled("GPU002", ctx.config) {
			add_gpu_diagnostic(ctx, e.loc, "GPU002",
				"F-string in @gpu function",
				"String operations require heap allocation and are not GPU-compatible",
				"Move string formatting outside the @gpu function")
		}

	// GPU003: Heap allocation
	case ^parser.List_Expr:
		if is_gpu_rule_enabled("GPU003", ctx.config) {
			add_gpu_diagnostic(ctx, e.loc, "GPU003",
				"List literal in @gpu function",
				"Lists require heap allocation which is not available on GPU",
				"Use Tensor types for collections of numeric data")
		}
	case ^parser.Dict_Expr:
		if is_gpu_rule_enabled("GPU003", ctx.config) {
			add_gpu_diagnostic(ctx, e.loc, "GPU003",
				"Dict literal in @gpu function",
				"Dicts require heap allocation which is not available on GPU",
				"Use Tensor types or pass data as parameters")
		}
	case ^parser.Set_Expr:
		if is_gpu_rule_enabled("GPU003", ctx.config) {
			add_gpu_diagnostic(ctx, e.loc, "GPU003",
				"Set literal in @gpu function",
				"Sets require heap allocation which is not available on GPU",
				"Use Tensor types for numeric data")
		}
	case ^parser.List_Comp:
		if is_gpu_rule_enabled("GPU003", ctx.config) {
			add_gpu_diagnostic(ctx, e.loc, "GPU003",
				"List comprehension in @gpu function",
				"Comprehensions allocate heap memory",
				"Use vectorized Tensor operations instead")
		}
	case ^parser.Set_Comp:
		if is_gpu_rule_enabled("GPU003", ctx.config) {
			add_gpu_diagnostic(ctx, e.loc, "GPU003",
				"Set comprehension in @gpu function",
				"Comprehensions allocate heap memory",
				"Use vectorized Tensor operations instead")
		}
	case ^parser.Dict_Comp:
		if is_gpu_rule_enabled("GPU003", ctx.config) {
			add_gpu_diagnostic(ctx, e.loc, "GPU003",
				"Dict comprehension in @gpu function",
				"Comprehensions allocate heap memory",
				"Use vectorized Tensor operations instead")
		}

	// GPU010: yield
	case ^parser.Yield_Expr:
		if is_gpu_rule_enabled("GPU010", ctx.config) {
			add_gpu_diagnostic(ctx, e.loc, "GPU010",
				"'yield' in @gpu function",
				"GPU kernels cannot be generators",
				"Remove yield and return results directly")
		}
	case ^parser.Yield_From_Expr:
		if is_gpu_rule_enabled("GPU010", ctx.config) {
			add_gpu_diagnostic(ctx, e.loc, "GPU010",
				"'yield from' in @gpu function",
				"GPU kernels cannot be generators",
				"Remove yield and return results directly")
		}

	// Check string constants for GPU001
	case ^parser.Constant_Expr:
		#partial switch _ in e.value {
		case string:
			if is_gpu_rule_enabled("GPU001", ctx.config) {
				add_gpu_diagnostic(ctx, e.loc, "GPU001",
					"String literal in @gpu function",
					"GPU compute operates on numeric data only",
					"Move string processing outside the @gpu function")
			}
		}

	// GPU006: Dynamic dispatch
	case ^parser.Call_Expr:
		check_call_for_gpu(e, ctx)
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
		if is_gpu_rule_enabled("GPU003", ctx.config) {
			add_gpu_diagnostic(ctx, e.loc, "GPU003",
				"Star expression (*args) in @gpu function",
				"Variable-length arguments require heap allocation",
				"Use fixed parameter lists instead")
		}
	}
}

// GPU005/GPU006/GPU007: Check function calls.
check_call_for_gpu :: proc(call: ^parser.Call_Expr, ctx: ^GPU_Restriction_Context) {
	#partial switch f in call.func {
	case ^parser.Name_Expr:
		// GPU005: Recursion (direct)
		if is_gpu_rule_enabled("GPU005", ctx.config) {
			if f.id == ctx.current_func {
				add_gpu_diagnostic(ctx, call.loc, "GPU005",
					fmt.tprintf("Recursive call to @gpu function '%s'", f.id),
					"GPU kernels cannot recurse — no call stack on GPU hardware",
					"Rewrite with iteration instead of recursion")
			}
		}
		// GPU006: Dynamic dispatch builtins
		if is_gpu_rule_enabled("GPU006", ctx.config) {
			DYNAMIC_DISPATCH :: [?]string{"getattr", "hasattr", "type", "isinstance", "issubclass", "eval", "exec", "compile"}
			for dd in DYNAMIC_DISPATCH {
				if f.id == dd {
					add_gpu_diagnostic(ctx, call.loc, "GPU006",
						fmt.tprintf("Dynamic dispatch function '%s()' in @gpu function", f.id),
						"Runtime type inspection is not available on GPU hardware",
						"Use static typing and compile-time type checks instead")
					break
				}
			}
		}
		// GPU002: str() and format()
		if is_gpu_rule_enabled("GPU002", ctx.config) {
			if f.id == "str" || f.id == "format" || f.id == "repr" || f.id == "print" {
				add_gpu_diagnostic(ctx, call.loc, "GPU002",
					fmt.tprintf("String operation '%s()' in @gpu function", f.id),
					"String operations require heap allocation and are not GPU-compatible",
					"Move string operations outside the @gpu function")
			}
		}
	case ^parser.Attribute_Expr:
		// GPU002: str method calls (e.g. x.format(), x.encode())
		if is_gpu_rule_enabled("GPU002", ctx.config) {
			STR_METHODS :: [?]string{"format", "encode", "decode", "split", "join", "strip", "replace", "upper", "lower"}
			for m in STR_METHODS {
				if f.attr == m {
					add_gpu_diagnostic(ctx, call.loc, "GPU002",
						fmt.tprintf("String method '.%s()' in @gpu function", f.attr),
						"String operations require heap allocation and are not GPU-compatible",
						"Move string processing outside the @gpu function")
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

add_gpu_diagnostic :: proc(ctx: ^GPU_Restriction_Context, loc: parser.Src_Loc, code: string, what: string, why: string, fix: string) {
	append(&ctx.diagnostics, core.Diagnostic{
		severity = .Error,
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
