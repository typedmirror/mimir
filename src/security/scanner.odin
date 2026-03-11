package security

import "core:mem"
import "core:strings"
import "core:fmt"
import parser "mimir:parser"
import binder "mimir:binder"
import core "mimir:core"
import flow "mimir:flow"
import taint "mimir:taint"

Security_Config :: struct {
	ignore:      []string,  // codes to skip, e.g. ["SEC003"]
	select_only: []string,  // codes to run (empty = all)
}

Security_Context :: struct {
	source:      string,
	lines:       []string,
	module:      ^parser.Module,
	bind_result: ^binder.Bind_Result,
	file_path:   string,
	config:      ^Security_Config,
	diagnostics: [dynamic]core.Diagnostic,
	import_map:  map[string]string,  // local_name → module_name
	allocator:   mem.Allocator,
}

default_config :: proc() -> Security_Config {
	return Security_Config{}
}

scan_file :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	source: string,
	file_path: string,
	config: ^Security_Config,
	allocator: mem.Allocator,
	flow_result: ^flow.Flow_Result = nil,
) -> []core.Diagnostic {
	ctx := Security_Context{
		source      = source,
		lines       = strings.split(source, "\n", allocator),
		module      = module,
		bind_result = bind_result,
		file_path   = file_path,
		config      = config,
		diagnostics = make([dynamic]core.Diagnostic, 0, 16, allocator),
		import_map  = make(map[string]string, 16, allocator),
		allocator   = allocator,
	}

	build_import_map(&ctx)
	run_all_rules(&ctx)

	// Taint analysis: two-pass when flow results are available
	// Pass 1: build function taint summaries (cross-function propagation)
	// Pass 2: analyze with summaries available at call sites
	if flow_result != nil {
		summaries := taint.build_summaries(flow_result.cfgs[:], bind_result, ctx.import_map, allocator)

		for &cfg in flow_result.cfgs {
			violations := taint.analyze_taint(&cfg, bind_result, ctx.import_map, allocator, summaries)
			for v in violations {
				if is_rule_enabled(v.rule_code, config) {
					append(&ctx.diagnostics, core.Diagnostic{
						severity = .Security,
						location = core.Location{
							file   = file_path,
							line   = int(v.sink_loc.line),
							column = int(v.sink_loc.col),
						},
						what = fmt.tprintf("tainted data flows to %s", v.sink_desc),
						why  = fmt.tprintf("data from %s (line %d) reaches %s without sanitization", v.source_desc, v.source_loc.line, v.sink_desc),
						fix  = "sanitize the input before passing it to a dangerous function, or use a safe alternative",
						code = v.rule_code,
					})
				}
			}
		}
	}

	return ctx.diagnostics[:]
}

// Build import_map from AST import statements.
// Maps local names to their source module.
build_import_map :: proc(ctx: ^Security_Context) {
	walk_imports_stmts(ctx, ctx.module.body)
}

walk_imports_stmts :: proc(ctx: ^Security_Context, stmts: []parser.Stmt) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Import_Stmt:
			for alias in s.names {
				local := alias.asname if len(alias.asname) > 0 else alias.name
				// For dotted imports without alias (e.g. "import os.path"), use first component
				if len(alias.asname) == 0 {
					for i := 0; i < len(local); i += 1 {
						if local[i] == '.' {
							local = local[:i]
							break
						}
					}
				}
				ctx.import_map[local] = alias.name
			}
		case ^parser.Import_From:
			if s.level > 0 { continue } // skip relative imports
			for alias in s.names {
				if alias.name == "*" { continue }
				local := alias.asname if len(alias.asname) > 0 else alias.name
				ctx.import_map[local] = s.module
			}
		case ^parser.Func_Def:
			walk_imports_stmts(ctx, s.body)
		case ^parser.Async_Func_Def:
			walk_imports_stmts(ctx, s.body)
		case ^parser.Class_Def:
			walk_imports_stmts(ctx, s.body)
		case ^parser.If_Stmt:
			walk_imports_stmts(ctx, s.body)
			walk_imports_stmts(ctx, s.orelse)
		}
	}
}

// Shared AST walkers for security rules

walk_stmts :: proc(ctx: ^Security_Context, stmts: []parser.Stmt, visit_expr: proc(ctx: ^Security_Context, expr: parser.Expr)) {
	for stmt in stmts {
		walk_stmt(ctx, stmt, visit_expr)
	}
}

walk_stmt :: proc(ctx: ^Security_Context, stmt: parser.Stmt, visit_expr: proc(ctx: ^Security_Context, expr: parser.Expr)) {
	#partial switch s in stmt {
	case ^parser.Expr_Stmt:
		walk_expr(ctx, s.value, visit_expr)
	case ^parser.Assign:
		walk_expr(ctx, s.value, visit_expr)
		for t in s.targets { walk_expr(ctx, t, visit_expr) }
	case ^parser.Ann_Assign:
		if s.value != nil { walk_expr(ctx, s.value, visit_expr) }
	case ^parser.Return_Stmt:
		if s.value != nil { walk_expr(ctx, s.value, visit_expr) }
	case ^parser.Func_Def:
		for st in s.body { walk_stmt(ctx, st, visit_expr) }
	case ^parser.Async_Func_Def:
		for st in s.body { walk_stmt(ctx, st, visit_expr) }
	case ^parser.Class_Def:
		for st in s.body { walk_stmt(ctx, st, visit_expr) }
	case ^parser.If_Stmt:
		walk_expr(ctx, s.test, visit_expr)
		for st in s.body { walk_stmt(ctx, st, visit_expr) }
		for st in s.orelse { walk_stmt(ctx, st, visit_expr) }
	case ^parser.For_Stmt:
		for st in s.body { walk_stmt(ctx, st, visit_expr) }
		for st in s.orelse { walk_stmt(ctx, st, visit_expr) }
	case ^parser.While_Stmt:
		walk_expr(ctx, s.test, visit_expr)
		for st in s.body { walk_stmt(ctx, st, visit_expr) }
		for st in s.orelse { walk_stmt(ctx, st, visit_expr) }
	case ^parser.With_Stmt:
		for st in s.body { walk_stmt(ctx, st, visit_expr) }
	case ^parser.Try_Stmt:
		for st in s.body { walk_stmt(ctx, st, visit_expr) }
		for h in s.handlers { for st in h.body { walk_stmt(ctx, st, visit_expr) } }
		for st in s.orelse { walk_stmt(ctx, st, visit_expr) }
		for st in s.finalbody { walk_stmt(ctx, st, visit_expr) }
	case ^parser.Assert_Stmt:
		walk_expr(ctx, s.test, visit_expr)
		if s.msg != nil { walk_expr(ctx, s.msg, visit_expr) }
	case ^parser.Raise_Stmt:
		if s.exc != nil { walk_expr(ctx, s.exc, visit_expr) }
	case ^parser.Aug_Assign:
		walk_expr(ctx, s.value, visit_expr)
		walk_expr(ctx, s.target, visit_expr)
	}
}

walk_expr :: proc(ctx: ^Security_Context, expr: parser.Expr, visit: proc(ctx: ^Security_Context, expr: parser.Expr)) {
	if expr == nil { return }
	visit(ctx, expr)

	#partial switch e in expr {
	case ^parser.Call_Expr:
		walk_expr(ctx, e.func, visit)
		for a in e.args { walk_expr(ctx, a, visit) }
		for kw in e.keywords { walk_expr(ctx, kw.value, visit) }
	case ^parser.Bin_Op_Expr:
		walk_expr(ctx, e.left, visit)
		walk_expr(ctx, e.right, visit)
	case ^parser.Unary_Op_Expr:
		walk_expr(ctx, e.operand, visit)
	case ^parser.Bool_Op_Expr:
		for v in e.values { walk_expr(ctx, v, visit) }
	case ^parser.Compare_Expr:
		walk_expr(ctx, e.left, visit)
		for c in e.comparators { walk_expr(ctx, c, visit) }
	case ^parser.If_Expr:
		walk_expr(ctx, e.test, visit)
		walk_expr(ctx, e.body, visit)
		walk_expr(ctx, e.orelse, visit)
	case ^parser.Dict_Expr:
		for k in e.keys { walk_expr(ctx, k, visit) }
		for v in e.values { walk_expr(ctx, v, visit) }
	case ^parser.Set_Expr:
		for elt in e.elts { walk_expr(ctx, elt, visit) }
	case ^parser.List_Expr:
		for elt in e.elts { walk_expr(ctx, elt, visit) }
	case ^parser.Tuple_Expr:
		for elt in e.elts { walk_expr(ctx, elt, visit) }
	case ^parser.Joined_Str:
		for v in e.values { walk_expr(ctx, v, visit) }
	case ^parser.Formatted_Value:
		walk_expr(ctx, e.value, visit)
	case ^parser.Attribute_Expr:
		walk_expr(ctx, e.value, visit)
	case ^parser.Subscript_Expr:
		walk_expr(ctx, e.value, visit)
		walk_expr(ctx, e.slice, visit)
	case ^parser.Starred_Expr:
		walk_expr(ctx, e.value, visit)
	}
}

// Resolve a Call_Expr's callee to (module, function_name).
// Returns ("", "") if not resolvable.
resolve_call :: proc(ctx: ^Security_Context, call: ^parser.Call_Expr) -> (module: string, func_name: string) {
	#partial switch f in call.func {
	case ^parser.Name_Expr:
		// Direct call: eval(), md5()
		// Check if it's an imported name
		if mod, ok := ctx.import_map[f.id]; ok {
			return mod, f.id
		}
		// Builtin (no module)
		return "", f.id
	case ^parser.Attribute_Expr:
		// Attribute call: hashlib.md5(), subprocess.run()
		if name, ok := f.value.(^parser.Name_Expr); ok {
			if mod, ok2 := ctx.import_map[name.id]; ok2 {
				return mod, f.attr
			}
			// Could be a method call on an object — not module-qualified
			return "", f.attr
		}
	}
	return "", ""
}

// Check if a variable name contains any security-relevant keyword
is_security_name :: proc(name: string) -> bool {
	lower := strings.to_lower(name, context.temp_allocator)
	keywords := [?]string{
		"token", "secret", "key", "password", "passwd", "nonce",
		"salt", "session", "csrf", "otp", "api_key", "apikey",
		"auth", "credential", "private_key",
	}
	for kw in keywords {
		if strings.contains(lower, kw) { return true }
	}
	return false
}
