package checker

import "core:fmt"
import "core:mem"

import parser "mimir:parser"
import binder "mimir:binder"
import core   "mimir:core"

// ==================== Crypt Analysis ====================
//
// Post-inference analysis pass for mimir.crypt misuse detection.
// Catches insecure cryptographic patterns at compile time:
//   CRYPT001 — Insecure encryption mode (ECB)
//   CRYPT002 — Weak hash for password hashing (MD5, SHA-1)
//   CRYPT003 — Insufficient key/token length

Crypt_Check_Context :: struct {
	reg:           ^Type_Registry,
	expr_types:    ^map[rawptr]Type_ID,
	file_path:     string,
	diagnostics:   ^[dynamic]core.Diagnostic,
	import_map:    map[string]string,  // local name → "mimir.crypt"
	allocator:     mem.Allocator,
}

// Entry point — called from checker.odin after type checking.
analyze_crypt :: proc(
	actx: ^Analysis_Pass_Context,
	virtual_types: ^map[binder.Symbol_ID]Type_ID,
	diagnostics: ^[dynamic]core.Diagnostic,
) {
	if !actx.has_import["mimir.crypt"] { return }

	// Domain-specific import map: local → original function name (hash, encrypt, etc.)
	import_map := make(map[string]string, 8, actx.allocator)
	for &imp in actx.bind_result.imports {
		if imp.module_name != "mimir.crypt" { continue }
		if len(imp.names) == 0 {
			import_map[imp.module_name] = imp.module_name
		} else {
			for imp_name in imp.names {
				local := imp_name.alias if len(imp_name.alias) > 0 else imp_name.name
				import_map[local] = imp_name.name
			}
		}
	}

	module := actx.module

	ctx := Crypt_Check_Context{
		reg           = actx.registry,
		expr_types    = actx.expr_types,
		file_path     = actx.file_path,
		diagnostics   = diagnostics,
		import_map    = import_map,
		allocator     = actx.allocator,
	}

	visitor := core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			ctx := cast(^Crypt_Check_Context)raw_ctx
			#partial switch e in expr {
			case ^parser.Call_Expr:
				check_crypt_call(ctx, e)
			}
		},
		ctx = rawptr(&ctx),
	}
	core.walk_all_stmts(&visitor, module.body)
}

// Build a visitor for batched execution
make_crypt_visitor :: proc(
	actx: ^Analysis_Pass_Context,
	diagnostics: ^[dynamic]core.Diagnostic,
	out_ctx: ^Crypt_Check_Context,
) -> (core.AST_Visitor, bool) {
	if !actx.has_import["mimir.crypt"] { return {}, false }

	import_map := make(map[string]string, 8, actx.allocator)
	for &imp in actx.bind_result.imports {
		if imp.module_name != "mimir.crypt" { continue }
		if len(imp.names) == 0 {
			import_map[imp.module_name] = imp.module_name
		} else {
			for imp_name in imp.names {
				local := imp_name.alias if len(imp_name.alias) > 0 else imp_name.name
				import_map[local] = imp_name.name
			}
		}
	}

	out_ctx^ = Crypt_Check_Context{
		reg         = actx.registry,
		expr_types  = actx.expr_types,
		file_path   = actx.file_path,
		diagnostics = diagnostics,
		import_map  = import_map,
		allocator   = actx.allocator,
	}
	return core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			ctx := cast(^Crypt_Check_Context)raw_ctx
			#partial switch e in expr {
			case ^parser.Call_Expr:
				check_crypt_call(ctx, e)
			}
		},
		ctx = rawptr(out_ctx),
	}, true
}

// Check if a Call_Expr is a mimir.crypt call and validate for misuse.
check_crypt_call :: proc(ctx: ^Crypt_Check_Context, e: ^parser.Call_Expr) {
	// We only care about attribute calls: namespace.method(...)
	attr, is_attr := e.func.(^parser.Attribute_Expr)
	if !is_attr { return }

	// Check if the value is a mimir.crypt import
	name, is_name := attr.value.(^parser.Name_Expr)
	if !is_name { return }

	orig_name, has := ctx.import_map[name.id]
	if !has { return }

	method := attr.attr

	// CRYPT001: Insecure encryption mode (ECB)
	if (orig_name == "encrypt" || orig_name == "decrypt") && method == "aes_ecb" {
		append(ctx.diagnostics, core.Diagnostic{
			severity = .Error,
			location = core.Location{
				file   = ctx.file_path,
				line   = int(e.loc.line),
				column = int(e.loc.col),
			},
			what = "insecure encryption mode: ECB",
			why  = "ECB mode encrypts identical plaintext blocks to identical ciphertext blocks, leaking patterns. It does not provide semantic security.",
			fix  = "Use encrypt.aes_gcm() (authenticated encryption) or encrypt.aes_cbc() instead",
			code = "CRYPT001",
		})
		return
	}

	// CRYPT002: Weak hash for password hashing
	if orig_name == "hash" && (method == "md5" || method == "sha1") {
		append(ctx.diagnostics, core.Diagnostic{
			severity = .Warning,
			location = core.Location{
				file   = ctx.file_path,
				line   = int(e.loc.line),
				column = int(e.loc.col),
			},
			what = fmt.tprintf("weak hash algorithm for password hashing: %s", method),
			why  = "MD5 and SHA-1 are fast hashes vulnerable to brute-force attacks. Password hashing requires slow, salted algorithms.",
			fix  = "Use hash.bcrypt() or hash.argon2() for password hashing",
			code = "CRYPT002",
		})
		return
	}

	// CRYPT003: Insufficient key/token length (bytes/urlsafe only — digits/hex n is not bytes)
	if orig_name == "token" && (method == "bytes" || method == "urlsafe") {
		if len(e.args) >= 1 {
			if constant, is_const := e.args[0].(^parser.Constant_Expr); is_const {
				if n, is_int := constant.value.(i64); is_int {
					if n < 16 {
						append(ctx.diagnostics, core.Diagnostic{
							severity = .Warning,
							location = core.Location{
								file   = ctx.file_path,
								line   = int(e.loc.line),
								column = int(e.loc.col),
							},
							what = fmt.tprintf("insufficient token length: %d bytes", n),
							why  = "Tokens shorter than 16 bytes (128 bits) may be vulnerable to brute-force attacks.",
							fix  = "Use at least 16 bytes (e.g., token.bytes(32)) for security-sensitive tokens",
							code = "CRYPT003",
						})
					}
				}
			}
		}
		return
	}
}
