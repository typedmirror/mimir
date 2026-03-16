package checker

import "core:fmt"
import "core:strings"
import "core:mem"

import parser "mimir:parser"
import binder "mimir:binder"
import core "mimir:core"

// ==================== Route Analysis ====================
//
// Post-inference analysis pass for mimir.http route validation.
// Discovers @route decorators, validates handler signatures,
// detects route conflicts.
//
// Diagnostics:
//   HTTP001 — Route handler missing Request parameter
//   HTTP002 — Route handler return type is not Response
//   HTTP003 — Duplicate route (same method + path)
//   HTTP004 — Path parameter not in handler signature

Route_Info :: struct {
	method:       string,
	path:         string,
	handler_name: string,
	handler_loc:  parser.Src_Loc,
	path_params:  []string,
}

Route_Context :: struct {
	module:         ^parser.Module,
	bind_result:    ^binder.Bind_Result,
	reg:            ^Type_Registry,
	virtual_types:  ^map[binder.Symbol_ID]Type_ID,
	file_path:      string,
	diagnostics:    ^[dynamic]core.Diagnostic,
	routes:         [dynamic]Route_Info,
	route_type_id:  Type_ID,  // Type_ID of the mimir.http.route callable (0 if not imported)
	allocator:      mem.Allocator,
}

// Entry point — called from checker.odin after type checking.
// Returns discovered routes for downstream API contract validation.
analyze_routes :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	reg: ^Type_Registry,
	virtual_types: ^map[binder.Symbol_ID]Type_ID,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) -> []Route_Info {
	// Find the Symbol_ID for the imported 'route' function
	route_type_id := find_route_symbol(bind_result, virtual_types, reg)
	if route_type_id == TYPE_UNKNOWN { return nil } // route not imported

	ctx := Route_Context{
		module        = module,
		bind_result   = bind_result,
		reg           = reg,
		virtual_types = virtual_types,
		file_path     = file_path,
		diagnostics   = diagnostics,
		routes        = make([dynamic]Route_Info, 0, 8, allocator),
		route_type_id = route_type_id,
		allocator     = allocator,
	}

	// Walk AST for decorated functions
	visitor := core.AST_Visitor{
		visit_stmt = proc(stmt: parser.Stmt, raw_ctx: rawptr) {
			ctx := cast(^Route_Context)raw_ctx
			#partial switch s in stmt {
			case ^parser.Func_Def:
				check_route_decorators(ctx, s.decorator_list, s.name, &s.args, s.returns, s.loc)
			case ^parser.Async_Func_Def:
				check_route_decorators(ctx, s.decorator_list, s.name, &s.args, s.returns, s.loc)
			}
		},
		ctx = rawptr(&ctx),
	}
	core.walk_all_stmts(&visitor, module.body)

	// Check for duplicate routes
	check_duplicate_routes(&ctx)

	return ctx.routes[:]
}

// Find the Type_ID that corresponds to mimir.http.route in virtual_types.
find_route_symbol :: proc(
	bind_result: ^binder.Bind_Result,
	virtual_types: ^map[binder.Symbol_ID]Type_ID,
	reg: ^Type_Registry,
) -> Type_ID {
	if virtual_types == nil { return TYPE_UNKNOWN }

	// Look for a symbol named "route" whose type is a Callable that returns a Callable
	mod_scope := binder.result_get_scope(bind_result, bind_result.module_scope)
	if mod_scope == nil { return TYPE_UNKNOWN }

	if sym_id, found := mod_scope.symbols["route"]; found {
		if type_id, has := virtual_types[sym_id]; has {
			// Verify it's a callable (the route decorator factory)
			t := get_type(reg, type_id)
			if t == nil { return TYPE_UNKNOWN }
			if _, ok := t.info.(Callable_Type); ok {
				return type_id
			}
		}
	}
	return TYPE_UNKNOWN
}

// Check if any decorator on a function is @route(method, path).
check_route_decorators :: proc(
	ctx: ^Route_Context,
	decorators: []parser.Expr,
	func_name: string,
	args: ^parser.Arguments,
	returns: parser.Expr,
	func_loc: parser.Src_Loc,
) {
	for dec in decorators {
		// @route("GET", "/path") is a Call_Expr
		call, is_call := dec.(^parser.Call_Expr)
		if !is_call { continue }

		// Check if the callee is the 'route' symbol
		name, is_name := call.func.(^parser.Name_Expr)
		if !is_name { continue }

		// Resolve name to symbol
		if !is_route_symbol(ctx, name) { continue }

		// Extract method and path from args
		if len(call.args) < 2 { continue }
		method := route_get_string_literal(call.args[0])
		path := route_get_string_literal(call.args[1])
		if len(method) == 0 || len(path) == 0 { continue }

		// Extract path parameters ({param} or <param>)
		path_params := extract_path_params(path, ctx.allocator)

		// Register route
		append(&ctx.routes, Route_Info{
			method       = method,
			path         = path,
			handler_name = func_name,
			handler_loc  = func_loc,
			path_params  = path_params,
		})

		// Validate handler signature
		validate_handler(ctx, args, returns, func_name, func_loc, path_params)
	}
}

// Check if a Name_Expr refers to the mimir.http.route symbol.
is_route_symbol :: proc(ctx: ^Route_Context, name: ^parser.Name_Expr) -> bool {
	if ctx.virtual_types == nil { return false }
	mod_scope := binder.result_get_scope(ctx.bind_result, ctx.bind_result.module_scope)
	if mod_scope == nil { return false }

	if sym_id, found := mod_scope.symbols[name.id]; found {
		if type_id, has := ctx.virtual_types[sym_id]; has {
			return type_id == ctx.route_type_id
		}
	}
	return false
}

// Validate that a route handler has the expected signature.
validate_handler :: proc(
	ctx: ^Route_Context,
	args: ^parser.Arguments,
	returns: parser.Expr,
	func_name: string,
	func_loc: parser.Src_Loc,
	path_params: []string,
) {
	// HTTP001: handler should have at least one parameter (Request)
	total_params := len(args.args) + len(args.posonlyargs)
	if total_params == 0 {
		append(ctx.diagnostics, core.Diagnostic{
			severity = .Error,
			location = core.Location{
				file   = ctx.file_path,
				line   = int(func_loc.line),
				column = int(func_loc.col),
			},
			what = fmt.tprintf("route handler '%s' has no Request parameter", func_name),
			why  = "route handlers receive a Request object as their first argument",
			fix  = fmt.tprintf("add a parameter: def %s(req: Request) -> Response", func_name),
			code = "HTTP001",
		})
	}

	// HTTP002: return type should be Response
	if returns != nil && ctx.reg.http_response_type != 0 {
		if ann_name, ok := returns.(^parser.Name_Expr); ok {
			mod_scope := binder.result_get_scope(ctx.bind_result, ctx.bind_result.module_scope)
			if mod_scope != nil {
				if sym_id, found := mod_scope.symbols[ann_name.id]; found {
					if type_id, has := ctx.virtual_types[sym_id]; has {
						inst := get_type(ctx.reg, ctx.reg.http_response_type)
						if inst != nil {
							if it, ok2 := inst.info.(Instance_Type); ok2 {
								if type_id != it.class_type {
									append(ctx.diagnostics, core.Diagnostic{
										severity = .Error,
										location = core.Location{
											file   = ctx.file_path,
											line   = int(func_loc.line),
											column = int(func_loc.col),
										},
										what = fmt.tprintf("route handler '%s' return type is not Response", func_name),
										why  = "route handlers should return a Response object",
										fix  = fmt.tprintf("annotate return type: def %s(...) -> Response", func_name),
										code = "HTTP002",
									})
								}
							}
						}
					}
				}
			}
		}
	} else if returns == nil && ctx.reg.http_response_type != 0 {
		// No return annotation — emit HTTP002 (only if Response type is available)
		append(ctx.diagnostics, core.Diagnostic{
			severity = .Error,
			location = core.Location{
				file   = ctx.file_path,
				line   = int(func_loc.line),
				column = int(func_loc.col),
			},
			what = fmt.tprintf("route handler '%s' has no return type annotation", func_name),
			why  = "route handlers should return a Response object",
			fix  = fmt.tprintf("add return annotation: def %s(...) -> Response", func_name),
			code = "HTTP002",
		})
	}

	// HTTP004: path parameters should appear in handler parameters
	if len(path_params) > 0 {
		// Collect handler param names
		handler_params := make(map[string]bool, 8, ctx.allocator)
		for &a in args.posonlyargs { handler_params[a.arg] = true }
		for &a in args.args { handler_params[a.arg] = true }
		for &a in args.kwonlyargs { handler_params[a.arg] = true }

		for pp in path_params {
			if pp not_in handler_params {
				append(ctx.diagnostics, core.Diagnostic{
					severity = .Error,
					location = core.Location{
						file   = ctx.file_path,
						line   = int(func_loc.line),
						column = int(func_loc.col),
					},
					what = fmt.tprintf("path parameter '%s' not in handler '%s' signature", pp, func_name),
					why  = "path parameters should be captured as handler function parameters",
					fix  = fmt.tprintf("add parameter: def %s(req: Request, %s: str) -> Response", func_name, pp),
					code = "HTTP004",
				})
			}
		}
	}
}

// Check for duplicate routes (same method + path).
check_duplicate_routes :: proc(ctx: ^Route_Context) {
	for i := 0; i < len(ctx.routes); i += 1 {
		for j := i + 1; j < len(ctx.routes); j += 1 {
			a := ctx.routes[i]
			b := ctx.routes[j]
			if a.method == b.method && a.path == b.path {
				append(ctx.diagnostics, core.Diagnostic{
					severity = .Error,
					location = core.Location{
						file   = ctx.file_path,
						line   = int(b.handler_loc.line),
						column = int(b.handler_loc.col),
					},
					what = fmt.tprintf("duplicate route %s %s (also defined by '%s')", b.method, b.path, a.handler_name),
					why  = "duplicate routes cause ambiguous request handling",
					fix  = fmt.tprintf("remove one of the handlers or use different paths"),
					code = "HTTP003",
				})
			}
		}
	}
}

// Extract path parameters from a route path.
// Supports {param} (FastAPI/OpenAPI) and <param> (Flask) syntax.
extract_path_params :: proc(path: string, allocator: mem.Allocator) -> []string {
	params := make([dynamic]string, 0, 4, allocator)
	i := 0
	for i < len(path) {
		if path[i] == '{' {
			end := strings.index_byte(path[i:], '}')
			if end > 1 {
				append(&params, path[i+1:i+end])
			}
			if end >= 0 { i += end + 1 } else { i += 1 }
		} else if path[i] == '<' {
			end := strings.index_byte(path[i:], '>')
			if end > 1 {
				param := path[i+1:i+end]
				// Strip Flask type constraint: <int:user_id> → user_id
				colon := strings.index_byte(param, ':')
				if colon >= 0 && colon < len(param) - 1 {
					param = param[colon+1:]
				}
				append(&params, param)
			}
			if end >= 0 { i += end + 1 } else { i += 1 }
		} else {
			i += 1
		}
	}
	return params[:]
}

// Get a string literal value from an expression.
route_get_string_literal :: proc(expr: parser.Expr) -> string {
	if expr == nil { return "" }
	if c, ok := expr.(^parser.Constant_Expr); ok {
		if s, s_ok := c.value.(string); s_ok {
			return s
		}
	}
	return ""
}
