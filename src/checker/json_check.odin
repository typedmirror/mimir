package checker

import "core:fmt"
import "core:mem"

import parser "mimir:parser"
import binder "mimir:binder"
import core   "mimir:core"

// ==================== JSON Analysis ====================
//
// Post-inference analysis pass for JSON serializability validation.
// Checks mimir.json.serialize/write/dump/dumps and stdlib json.dumps/dump
// for non-serializable argument types.
//
// Diagnostics:
//   JSON001 — Non-serializable type passed to JSON serialization
//   JSON003 — TypedDict schema field has non-serializable type

JSON_Check_Context :: struct {
	reg:           ^Type_Registry,
	expr_types:    ^map[rawptr]Type_ID,
	file_path:     string,
	diagnostics:   ^[dynamic]core.Diagnostic,
	import_map:    map[string]string,  // name → module (e.g., "json" → "json")
	allocator:     mem.Allocator,
}

// Entry point — called from checker.odin after type checking.
analyze_json :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	reg: ^Type_Registry,
	virtual_types: ^map[binder.Symbol_ID]Type_ID,
	expr_types: ^map[rawptr]Type_ID,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	// Build import map for stdlib json detection
	import_map := make(map[string]string, 8, allocator)
	for &imp in bind_result.imports {
		if len(imp.names) == 0 {
			// "import json" → map "json" → "json"
			import_map[imp.module_name] = imp.module_name
		} else {
			// "from json import dumps" → map "dumps" → "json"
			for imp_name in imp.names {
				local := imp_name.alias if len(imp_name.alias) > 0 else imp_name.name
				import_map[local] = imp.module_name
			}
		}
	}

	ctx := JSON_Check_Context{
		reg           = reg,
		expr_types    = expr_types,
		file_path     = file_path,
		diagnostics   = diagnostics,
		import_map    = import_map,
		allocator     = allocator,
	}

	visitor := core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			ctx := cast(^JSON_Check_Context)raw_ctx
			#partial switch e in expr {
			case ^parser.Call_Expr:
				check_json_call(ctx, e)
			}
		},
		ctx = rawptr(&ctx),
	}
	core.walk_all_stmts(&visitor, module.body)
}

// Check if a Call_Expr is a JSON serialization call and validate its argument.
check_json_call :: proc(ctx: ^JSON_Check_Context, e: ^parser.Call_Expr) {
	// Check mimir.json virtual module calls
	if ctx.reg.json_serialize_type != 0 {
		if arg_type, ok := resolve_json_serialize_arg(ctx, e); ok {
			check_serializability(ctx, arg_type, e.loc)
			return
		}
	}

	// Check stdlib json.dumps / json.dump
	check_stdlib_json_dump(ctx, e)
}

// Resolve first argument type if call is to a mimir.json serialize/write/dump/dumps.
resolve_json_serialize_arg :: proc(ctx: ^JSON_Check_Context, e: ^parser.Call_Expr) -> (Type_ID, bool) {
	if len(e.args) == 0 { return TYPE_UNKNOWN, false }

	// Get the callee's inferred type
	callee_type := TYPE_UNKNOWN
	if ct, ok := ctx.expr_types[expr_to_rawptr(e.func)]; ok {
		callee_type = ct
	}
	if callee_type == TYPE_UNKNOWN || callee_type == TYPE_ANY { return TYPE_UNKNOWN, false }

	// Check against known mimir.json serialize callables
	if callee_type == ctx.reg.json_serialize_type ||
	   callee_type == ctx.reg.json_write_type ||
	   callee_type == ctx.reg.json_dump_type ||
	   callee_type == ctx.reg.json_dumps_type {
		// Get first argument type from expr_types
		if arg_type, ok := ctx.expr_types[expr_to_rawptr(e.args[0])]; ok {
			return arg_type, true
		}
	}
	return TYPE_UNKNOWN, false
}

// Check stdlib json.dumps(obj) / json.dump(obj, fp) calls.
check_stdlib_json_dump :: proc(ctx: ^JSON_Check_Context, e: ^parser.Call_Expr) {
	if len(e.args) == 0 { return }

	is_json_dump := false

	#partial switch f in e.func {
	case ^parser.Attribute_Expr:
		// json.dumps(...) or json.dump(...)
		if name, ok := f.value.(^parser.Name_Expr); ok {
			if mod, has := ctx.import_map[name.id]; has && mod == "json" {
				if f.attr == "dumps" || f.attr == "dump" {
					is_json_dump = true
				}
			}
		}
	case ^parser.Name_Expr:
		// from json import dumps → dumps(...)
		if mod, has := ctx.import_map[f.id]; has && mod == "json" {
			if f.id == "dumps" || f.id == "dump" {
				is_json_dump = true
			}
		}
	}

	if !is_json_dump { return }

	// Get first argument type
	if arg_type, ok := ctx.expr_types[expr_to_rawptr(e.args[0])]; ok {
		check_serializability(ctx, arg_type, e.loc)
	}
}

// Validate TypedDict schema fields are JSON-serializable (JSON003).
// Called from infer.odin when TypedDict is used as a parse/read schema arg.
check_json_schema_fields :: proc(ctx: ^Infer_Context, schema_type: Type_ID, loc: parser.Src_Loc) {
	t := get_type(ctx.reg, schema_type)
	if t == nil { return }
	td, ok := t.info.(TypedDict_Type)
	if !ok { return }

	for field_name, field_type in td.fields {
		visited := make(map[Type_ID]bool, 8, ctx.reg.allocator)
		if !is_json_serializable(ctx.reg, field_type, &visited) {
			emit_diagnostic(ctx, loc, "JSON003", .Error,
				"Non-serializable schema field",
				fmt.aprintf("TypedDict '%s' field '%s' has type '%s' which is not JSON serializable",
					td.name, field_name, type_to_string(ctx.reg, field_type),
					allocator = ctx.reg.allocator),
				"change the field type to a JSON-compatible type")
		}
	}
}

// Emit JSON001 if the type is not JSON-serializable.
check_serializability :: proc(ctx: ^JSON_Check_Context, type_id: Type_ID, loc: parser.Src_Loc) {
	if type_id == TYPE_UNKNOWN || type_id == TYPE_ANY { return }

	visited := make(map[Type_ID]bool, 8, ctx.allocator)
	if !is_json_serializable(ctx.reg, type_id, &visited) {
		append(ctx.diagnostics, core.Diagnostic{
			severity = .Error,
			location = core.Location{
				file   = ctx.file_path,
				line   = int(loc.line),
				column = int(loc.col),
			},
			what = fmt.tprintf("type '%s' is not JSON serializable", type_to_string(ctx.reg, type_id)),
			why  = "json.dumps/serialize requires JSON-compatible types (str, int, float, bool, None, list, dict[str, ...])",
			fix  = "convert to a serializable type or use a custom encoder",
			code = "JSON001",
		})
	}
}

// Recursive JSON serializability check.
is_json_serializable :: proc(reg: ^Type_Registry, type_id: Type_ID, visited: ^map[Type_ID]bool) -> bool {
	// Primitives
	if type_id == TYPE_STR || type_id == TYPE_INT || type_id == TYPE_FLOAT ||
	   type_id == TYPE_BOOL || type_id == TYPE_NONE ||
	   type_id == TYPE_ANY || type_id == TYPE_UNKNOWN {
		return true
	}

	// Cycle guard for self-referential types
	if type_id in visited^ { return true }
	visited[type_id] = true

	t := get_type(reg, type_id)
	if t == nil { return true }

	#partial switch info in t.info {
	case List_Type:
		return is_json_serializable(reg, info.element, visited)
	case Tuple_Type:
		for elem in info.elements {
			if !is_json_serializable(reg, elem, visited) { return false }
		}
		return true
	case Dict_Type:
		if info.key != TYPE_STR && info.key != TYPE_ANY { return false }
		return is_json_serializable(reg, info.value, visited)
	case TypedDict_Type:
		for _, field_type in info.fields {
			if !is_json_serializable(reg, field_type, visited) { return false }
		}
		return true
	case Union_Type:
		for variant in info.members {
			if !is_json_serializable(reg, variant, visited) { return false }
		}
		return true
	case Literal_Int_Type, Literal_Str_Type, Literal_Bool_Type:
		return true
	case Set_Type:
		return false
	case Instance_Type:
		return false
	case Callable_Type:
		return false
	case Module_Type:
		return false
	case Tensor_Type:
		return false
	}
	return false
}
