package checker

import "core:fmt"
import "core:mem"

import parser "mimir:parser"
import binder "mimir:binder"
import core   "mimir:core"

// ==================== Time & Encoding Analysis ====================
//
// Post-inference analysis pass for datetime safety and encoding correctness.
//
// Diagnostics:
//   TIME001 — Naive/aware datetime mixing (arithmetic/comparison between naive and aware)
//   ENC001  — str passed to bytes-expecting function (hashlib, hmac)

Datetime_Kind :: enum u8 {
	Unknown,
	Naive,
	Aware,
}

Time_Enc_Context :: struct {
	file_path:     string,
	diagnostics:   ^[dynamic]core.Diagnostic,
	expr_types:    ^map[rawptr]Type_ID,
	datetime_vars: map[string]Datetime_Kind,
	has_datetime:  bool,
	has_hashlib:   bool,
	has_hmac:      bool,
	allocator:     mem.Allocator,
}

// Entry point — called from checker.odin after type checking.
analyze_time_encoding :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	expr_types: ^map[rawptr]Type_ID,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	has_datetime := false
	has_hashlib := false
	has_hmac := false

	for &imp in bind_result.imports {
		if imp.module_name == "datetime" { has_datetime = true }
		if imp.module_name == "hashlib"  { has_hashlib = true }
		if imp.module_name == "hmac"     { has_hmac = true }
	}

	if !has_datetime && !has_hashlib && !has_hmac { return }

	// Analyze each function body independently
	for stmt in module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			analyze_te_in_body(s.body, file_path, diagnostics, expr_types, has_datetime, has_hashlib, has_hmac, allocator)
		case ^parser.Async_Func_Def:
			analyze_te_in_body(s.body, file_path, diagnostics, expr_types, has_datetime, has_hashlib, has_hmac, allocator)
		}
	}
}

analyze_te_in_body :: proc(
	body: []parser.Stmt,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	expr_types: ^map[rawptr]Type_ID,
	has_datetime: bool,
	has_hashlib: bool,
	has_hmac: bool,
	allocator: mem.Allocator,
) {
	ctx := Time_Enc_Context{
		file_path     = file_path,
		diagnostics   = diagnostics,
		expr_types    = expr_types,
		datetime_vars = make(map[string]Datetime_Kind, 8, allocator),
		has_datetime  = has_datetime,
		has_hashlib   = has_hashlib,
		has_hmac      = has_hmac,
		allocator     = allocator,
	}

	// Pass 1: Collect datetime variable kinds
	if has_datetime {
		for stmt in body {
			collect_datetime_vars(&ctx, stmt)
		}
	}

	// Pass 2: Validate datetime mixing + encoding calls
	visitor := core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			ctx := cast(^Time_Enc_Context)raw_ctx
			// TIME001: datetime mixing
			if ctx.has_datetime && len(ctx.datetime_vars) > 0 {
				check_datetime_mixing(ctx, expr)
			}
			// ENC001: str to hashlib/hmac
			if ctx.has_hashlib || ctx.has_hmac {
				check_encoding_call(ctx, expr)
			}
		},
		ctx = rawptr(&ctx),
	}
	core.walk_all_stmts(&visitor, body)
}

// ==================== TIME001: Datetime Collection ====================

collect_datetime_vars :: proc(ctx: ^Time_Enc_Context, stmt: parser.Stmt) {
	#partial switch s in stmt {
	case ^parser.Assign:
		if len(s.targets) != 1 { return }
		name, is_name := s.targets[0].(^parser.Name_Expr)
		if !is_name { return }

		call, is_call := s.value.(^parser.Call_Expr)
		if !is_call { return }

		kind := classify_datetime_call(call)
		if kind != .Unknown {
			ctx.datetime_vars[name.id] = kind
		}

	case ^parser.If_Stmt:
		for sub in s.body { collect_datetime_vars(ctx, sub) }
		for sub in s.orelse { collect_datetime_vars(ctx, sub) }
	case ^parser.For_Stmt:
		for sub in s.body { collect_datetime_vars(ctx, sub) }
		for sub in s.orelse { collect_datetime_vars(ctx, sub) }
	case ^parser.While_Stmt:
		for sub in s.body { collect_datetime_vars(ctx, sub) }
		for sub in s.orelse { collect_datetime_vars(ctx, sub) }
	case ^parser.With_Stmt:
		for sub in s.body { collect_datetime_vars(ctx, sub) }
	case ^parser.Try_Stmt:
		for sub in s.body { collect_datetime_vars(ctx, sub) }
		for sub in s.orelse { collect_datetime_vars(ctx, sub) }
		for sub in s.finalbody { collect_datetime_vars(ctx, sub) }
		for &handler in s.handlers {
			for sub in handler.body { collect_datetime_vars(ctx, sub) }
		}
	}
}

classify_datetime_call :: proc(call: ^parser.Call_Expr) -> Datetime_Kind {
	attr, is_attr := call.func.(^parser.Attribute_Expr)
	if !is_attr { return .Unknown }

	// datetime.datetime.now(...) or datetime.now(...)
	base_name := get_datetime_base(attr)
	if len(base_name) == 0 { return .Unknown }

	// datetime.now() → Naive, datetime.now(tz=...) → Aware
	if attr.attr == "now" {
		if has_tz_arg(call) {
			return .Aware
		}
		return .Naive
	}

	// datetime.utcnow() → Naive
	if attr.attr == "utcnow" {
		return .Naive
	}

	return .Unknown
}

// Check if call base is "datetime" (either datetime.now or datetime.datetime.now)
get_datetime_base :: proc(attr: ^parser.Attribute_Expr) -> string {
	// datetime.now() — base is Name_Expr "datetime"
	if name, ok := attr.value.(^parser.Name_Expr); ok {
		if name.id == "datetime" { return "datetime" }
	}

	// datetime.datetime.now() — base is Attribute_Expr(datetime, "datetime")
	if inner_attr, ok := attr.value.(^parser.Attribute_Expr); ok {
		if inner_name, ok2 := inner_attr.value.(^parser.Name_Expr); ok2 {
			if inner_name.id == "datetime" && inner_attr.attr == "datetime" {
				return "datetime"
			}
		}
	}

	return ""
}

// Check if call has tz= keyword arg, or a positional arg (datetime.now(timezone.utc))
has_tz_arg :: proc(call: ^parser.Call_Expr) -> bool {
	// Check keyword args for tz=
	for kw in call.keywords {
		if kw.arg == "tz" { return true }
	}

	// Check positional arg — datetime.now(timezone.utc)
	if len(call.args) >= 1 { return true }

	return false
}

// ==================== TIME001: Mixing Validation ====================

check_datetime_mixing :: proc(ctx: ^Time_Enc_Context, expr: parser.Expr) {
	// Check binary operations: a - b, a + b, a < b, a > b, etc.
	binop, is_binop := expr.(^parser.Bin_Op_Expr)
	if is_binop {
		left_kind := get_expr_datetime_kind(ctx, binop.left)
		right_kind := get_expr_datetime_kind(ctx, binop.right)

		if left_kind != .Unknown && right_kind != .Unknown && left_kind != right_kind {
			append(ctx.diagnostics, core.Diagnostic{
				severity = .Warning,
				location = core.Location{
					file   = ctx.file_path,
					line   = int(binop.loc.line),
					column = int(binop.loc.col),
				},
				what = fmt.tprintf("mixing %s and %s datetime objects", kind_str(left_kind), kind_str(right_kind)),
				why  = "arithmetic or comparison between naive and aware datetimes raises TypeError at runtime",
				fix  = "ensure both datetimes are either naive or aware (use .replace(tzinfo=...) or .astimezone())",
				code = "TIME001",
			})
		}
		return
	}

	// Check compare operations: a < b, a == b, etc.
	cmp, is_cmp := expr.(^parser.Compare_Expr)
	if is_cmp {
		left_kind := get_expr_datetime_kind(ctx, cmp.left)
		if left_kind == .Unknown { return }

		for comp in cmp.comparators {
			right_kind := get_expr_datetime_kind(ctx, comp)
			if right_kind != .Unknown && left_kind != right_kind {
				append(ctx.diagnostics, core.Diagnostic{
					severity = .Warning,
					location = core.Location{
						file   = ctx.file_path,
						line   = int(cmp.loc.line),
						column = int(cmp.loc.col),
					},
					what = fmt.tprintf("comparing %s and %s datetime objects", kind_str(left_kind), kind_str(right_kind)),
					why  = "comparison between naive and aware datetimes raises TypeError at runtime",
					fix  = "ensure both datetimes are either naive or aware",
					code = "TIME001",
				})
				break
			}
		}
	}
}

get_expr_datetime_kind :: proc(ctx: ^Time_Enc_Context, expr: parser.Expr) -> Datetime_Kind {
	// Direct variable reference
	if name, ok := expr.(^parser.Name_Expr); ok {
		if kind, found := ctx.datetime_vars[name.id]; found {
			return kind
		}
	}

	// Inline call: datetime.now() - datetime.now(tz=...)
	if call, ok := expr.(^parser.Call_Expr); ok {
		return classify_datetime_call(call)
	}

	return .Unknown
}

kind_str :: proc(k: Datetime_Kind) -> string {
	switch k {
	case .Naive:   return "naive"
	case .Aware:   return "aware"
	case .Unknown: return "unknown"
	}
	return "unknown"
}

// ==================== ENC001: Encoding Validation ====================

check_encoding_call :: proc(ctx: ^Time_Enc_Context, expr: parser.Expr) {
	call, is_call := expr.(^parser.Call_Expr)
	if !is_call { return }

	attr, is_attr := call.func.(^parser.Attribute_Expr)
	if !is_attr { return }

	base, is_name := attr.value.(^parser.Name_Expr)
	if !is_name { return }

	// hashlib.sha256(data), hashlib.md5(data), etc.
	if ctx.has_hashlib && base.id == "hashlib" {
		HASH_FUNCS :: [?]string{
			"sha256", "sha512", "sha1", "md5",
			"sha224", "sha384", "sha3_256", "sha3_512",
			"blake2b", "blake2s",
		}

		for fn in HASH_FUNCS {
			if attr.attr == fn {
				// First arg is data
				if len(call.args) >= 1 {
					check_bytes_arg(ctx, call.args[0], call.loc, fn, "")
				}
				return
			}
		}

		// hashlib.new(name, data) — second arg
		if attr.attr == "new" {
			if len(call.args) >= 2 {
				check_bytes_arg(ctx, call.args[1], call.loc, "hashlib.new", "data")
			}
			return
		}

		// hashlib.pbkdf2_hmac(name, password, salt, ...) — 2nd and 3rd args
		if attr.attr == "pbkdf2_hmac" {
			if len(call.args) >= 2 {
				check_bytes_arg(ctx, call.args[1], call.loc, "pbkdf2_hmac", "password")
			}
			if len(call.args) >= 3 {
				check_bytes_arg(ctx, call.args[2], call.loc, "pbkdf2_hmac", "salt")
			}
			return
		}
	}

	// hmac.new(key, msg, ...) — 1st and 2nd args
	if ctx.has_hmac && base.id == "hmac" && attr.attr == "new" {
		if len(call.args) >= 1 {
			check_bytes_arg(ctx, call.args[0], call.loc, "hmac.new", "key")
		}
		if len(call.args) >= 2 {
			check_bytes_arg(ctx, call.args[1], call.loc, "hmac.new", "msg")
		}
	}
}

check_bytes_arg :: proc(ctx: ^Time_Enc_Context, arg: parser.Expr, loc: parser.Src_Loc, func_name: string, arg_name: string) {
	arg_type := TYPE_UNKNOWN
	if t, ok := ctx.expr_types[expr_to_rawptr(arg)]; ok {
		arg_type = t
	}

	if arg_type == TYPE_STR {
		what_msg: string
		if len(arg_name) > 0 {
			what_msg = fmt.tprintf("%s: '%s' argument expects bytes, got str", func_name, arg_name)
		} else {
			what_msg = fmt.tprintf("%s expects bytes argument, got str", func_name)
		}
		append(ctx.diagnostics, core.Diagnostic{
			severity = .Error,
			location = core.Location{
				file   = ctx.file_path,
				line   = int(loc.line),
				column = int(loc.col),
			},
			what = what_msg,
			why  = "passing str to a function that expects bytes raises TypeError",
			fix  = "encode the string first: value.encode() or value.encode('utf-8')",
			code = "ENC001",
		})
	}
}
