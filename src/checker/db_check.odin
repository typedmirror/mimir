package checker

import "core:fmt"
import "core:mem"

import parser "mimir:parser"
import binder "mimir:binder"
import core   "mimir:core"

// ==================== DB Analysis ====================
//
// Post-inference analysis pass for SQL injection detection.
// Checks mimir.db.query/execute and Connection.query/execute
// for unsafe SQL string construction (f-strings, concatenation, .format()).
//
// Diagnostics:
//   DB001 — Unsafe SQL construction (use parameterized queries)

DB_Check_Context :: struct {
	reg:           ^Type_Registry,
	expr_types:    ^map[rawptr]Type_ID,
	file_path:     string,
	diagnostics:   ^[dynamic]core.Diagnostic,
	import_map:    map[string]string,  // name → module (e.g., "query" → "mimir.db")
	allocator:     mem.Allocator,
}

// Entry point — called from checker.odin after type checking.
analyze_db :: proc(
	actx: ^Analysis_Pass_Context,
	virtual_types: ^map[binder.Symbol_ID]Type_ID,
	diagnostics: ^[dynamic]core.Diagnostic,
) {
	reg := actx.registry
	// Quick check: skip if no mimir.db imports and no virtual db types
	has_db_import := actx.has_import["mimir.db"]
	has_db_virtual := reg != nil && reg.db_query_type != 0
	if !has_db_import && !has_db_virtual { return }

	// Build domain-specific import map (only mimir.db names)
	import_map := make(map[string]string, 8, actx.allocator)
	for &imp in actx.bind_result.imports {
		if imp.module_name != "mimir.db" { continue }
		if len(imp.names) == 0 {
			import_map[imp.module_name] = imp.module_name
		} else {
			for imp_name in imp.names {
				local := imp_name.alias if len(imp_name.alias) > 0 else imp_name.name
				import_map[local] = imp.module_name
			}
		}
	}

	module := actx.module
	file_path := actx.file_path
	expr_types := actx.expr_types
	allocator := actx.allocator

	ctx := DB_Check_Context{
		reg           = reg,
		expr_types    = expr_types,
		file_path     = file_path,
		diagnostics   = diagnostics,
		import_map    = import_map,
		allocator     = allocator,
	}

	visitor := core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			ctx := cast(^DB_Check_Context)raw_ctx
			#partial switch e in expr {
			case ^parser.Call_Expr:
				check_db_call(ctx, e)
			}
		},
		ctx = rawptr(&ctx),
	}
	core.walk_all_stmts(&visitor, module.body)
}

// Build a visitor for batched execution (returns nil visitor if pass should be skipped)
make_db_visitor :: proc(
	actx: ^Analysis_Pass_Context,
	virtual_types: ^map[binder.Symbol_ID]Type_ID,
	diagnostics: ^[dynamic]core.Diagnostic,
	out_ctx: ^DB_Check_Context,
) -> (core.AST_Visitor, bool) {
	reg := actx.registry
	has_db_import := actx.has_import["mimir.db"]
	has_db_virtual := reg != nil && reg.db_query_type != 0
	if !has_db_import && !has_db_virtual { return {}, false }

	import_map := make(map[string]string, 8, actx.allocator)
	for &imp in actx.bind_result.imports {
		if imp.module_name != "mimir.db" { continue }
		if len(imp.names) == 0 {
			import_map[imp.module_name] = imp.module_name
		} else {
			for imp_name in imp.names {
				local := imp_name.alias if len(imp_name.alias) > 0 else imp_name.name
				import_map[local] = imp.module_name
			}
		}
	}

	out_ctx^ = DB_Check_Context{
		reg         = reg,
		expr_types  = actx.expr_types,
		file_path   = actx.file_path,
		diagnostics = diagnostics,
		import_map  = import_map,
		allocator   = actx.allocator,
	}

	return core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			ctx := cast(^DB_Check_Context)raw_ctx
			#partial switch e in expr {
			case ^parser.Call_Expr:
				check_db_call(ctx, e)
			}
		},
		ctx = rawptr(out_ctx),
	}, true
}

// Check if a Call_Expr is a mimir.db query/execute call and validate its SQL argument.
check_db_call :: proc(ctx: ^DB_Check_Context, e: ^parser.Call_Expr) {
	is_db_call := false
	sql_arg_idx := 1  // Default: second arg (after conn) for module-level query/execute

	// Check by callee type (covers both import styles via virtual module resolution)
	if ctx.reg.db_query_type != 0 {
		if callee_type, ok := ctx.expr_types[expr_to_rawptr(e.func)]; ok {
			if callee_type == ctx.reg.db_query_type || callee_type == ctx.reg.db_execute_type {
				is_db_call = true
				sql_arg_idx = 1  // query(conn, sql, ...) — sql is at index 1
			} else if callee_type == ctx.reg.db_conn_query_type || callee_type == ctx.reg.db_conn_execute_type {
				is_db_call = true
				sql_arg_idx = 0  // conn.query(sql, ...) — sql is at index 0
			}
		}
	}

	// Fallback: check by import name
	if !is_db_call {
		#partial switch f in e.func {
		case ^parser.Name_Expr:
			if mod, has := ctx.import_map[f.id]; has && mod == "mimir.db" {
				if f.id == "query" || f.id == "execute" {
					is_db_call = true
					sql_arg_idx = 1
				}
			}
		case ^parser.Attribute_Expr:
			// db.query(...) or conn.query/execute(...)
			if name, ok := f.value.(^parser.Name_Expr); ok {
				// Check if it's a module-level access (db.query)
				if mod, has := ctx.import_map[name.id]; has && mod == "mimir.db" {
					if f.attr == "query" || f.attr == "execute" {
						is_db_call = true
						sql_arg_idx = 1
					}
				}
			}
			// Check if it's a method call (conn.query, conn.execute)
			if f.attr == "query" || f.attr == "execute" {
				if val_type, ok := ctx.expr_types[expr_to_rawptr(f.value)]; ok {
					// Match by registered type ID, not class name (avoids false positives on user-defined Connection classes)
					if ctx.reg.db_conn_query_type != 0 {
						vt := get_type(ctx.reg, val_type)
						if vt != nil {
							#partial switch inst in vt.info {
							case Instance_Type:
								ct := get_type(ctx.reg, inst.class_type)
								if ct != nil {
									if cls, ok2 := ct.info.(Class_Type); ok2 {
										// Verify this class has the exact mimir.db callable types
										if q, has_q := cls.attrs["query"]; has_q {
											if q == ctx.reg.db_conn_query_type {
												is_db_call = true
												sql_arg_idx = 0
											}
										}
									}
								}
							}
						}
					}
				}
			}
		}
	}

	if !is_db_call { return }

	// Check SQL argument for unsafe construction
	if sql_arg_idx >= len(e.args) { return }
	sql_arg := e.args[sql_arg_idx]

	check_sql_arg_safety(ctx, sql_arg, e.loc)
}

// Check if a SQL argument uses unsafe string construction.
check_sql_arg_safety :: proc(ctx: ^DB_Check_Context, sql_arg: parser.Expr, call_loc: parser.Src_Loc) {
	#partial switch arg in sql_arg {
	case ^parser.Constant_Expr:
		// String/numeric literal — safe
		return
	case ^parser.Joined_Str:
		// f-string — always unsafe for SQL
		emit_db001(ctx, call_loc, "f-string interpolation in SQL query")
		return
	case ^parser.Bin_Op_Expr:
		// String concatenation with + — check if it's dynamic
		if arg.op == .Add {
			// If either side is not a string literal, it's dynamic concatenation
			_, left_lit  := arg.left.(^parser.Constant_Expr)
			_, right_lit := arg.right.(^parser.Constant_Expr)
			if !left_lit || !right_lit {
				emit_db001(ctx, call_loc, "string concatenation in SQL query")
				return
			}
		}
	case ^parser.Call_Expr:
		// Check for "...".format(...) pattern
		if attr, ok := arg.func.(^parser.Attribute_Expr); ok {
			if attr.attr == "format" {
				emit_db001(ctx, call_loc, "str.format() in SQL query")
				return
			}
		}
	}
}

// Emit DB001 diagnostic.
emit_db001 :: proc(ctx: ^DB_Check_Context, loc: parser.Src_Loc, detail: string) {
	append(ctx.diagnostics, core.Diagnostic{
		severity = .Error,
		location = core.Location{
			file   = ctx.file_path,
			line   = int(loc.line),
			column = int(loc.col),
		},
		what = fmt.tprintf("unsafe SQL construction: %s", detail),
		why  = "Dynamic SQL construction is vulnerable to SQL injection. Use parameterized queries with ? placeholders.",
		fix  = "Use query(db, \"SELECT * FROM users WHERE id = ?\", params=[user_id])",
		code = "DB001",
	})
}
