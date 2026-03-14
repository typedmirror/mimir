package security

import "core:fmt"
import "core:strings"
import parser "mimir:parser"
import core "mimir:core"

// SEC001 — Weak hash algorithm (md5, sha1)
check_weak_hash :: proc(ctx: ^Security_Context) {
	walk_stmts(ctx, ctx.module.body, proc(ctx: ^Security_Context, expr: parser.Expr) {
		call, ok := expr.(^parser.Call_Expr)
		if !ok { return }

		mod, func_name := resolve_call(ctx, call)

		weak := false
		algo := ""

		if mod == "hashlib" {
			switch func_name {
			case "md5":
				weak = true
				algo = "md5"
			case "sha1":
				weak = true
				algo = "sha1"
			}
		} else if mod == "" && (func_name == "md5" || func_name == "sha1") {
			// Direct call after `from hashlib import md5`
			// Already handled by resolve_call returning mod="hashlib"
		}

		// Also check hashlib.new("md5") pattern
		if mod == "hashlib" && func_name == "new" && len(call.args) > 0 {
			if c, c_ok := call.args[0].(^parser.Constant_Expr); c_ok {
				if s, s_ok := c.value.(string); s_ok {
					lower := strings.to_lower(s, context.temp_allocator)
					if lower == "md5" || lower == "sha1" {
						weak = true
						algo = lower
					}
				}
			}
		}

		if weak {
			append(&ctx.diagnostics, core.Diagnostic{
				severity = .Security,
				location = core.Location{
					file   = ctx.file_path,
					line   = int(call.loc.line),
					column = int(call.loc.col),
				},
				what = fmt.tprintf("weak hash algorithm '%s' is not suitable for security use", algo),
				why  = "MD5 and SHA-1 are cryptographically broken and vulnerable to collision attacks",
				fix  = "use hashlib.sha256() or bcrypt/argon2 for passwords",
				code = "SEC001",
			})
		}
	})
}

// SEC002 — Insecure randomness for security-sensitive values
check_insecure_random :: proc(ctx: ^Security_Context) {
	// Walk assignments to find: token = random.choice(...)
	for stmt in ctx.module.body {
		walk_assign_random(ctx, stmt)
	}
}

walk_assign_random :: proc(ctx: ^Security_Context, stmt: parser.Stmt) {
	#partial switch s in stmt {
	case ^parser.Assign:
		// Check if value is a random.* call
		if call, ok := s.value.(^parser.Call_Expr); ok {
			mod, func_name := resolve_call(ctx, call)
			if mod == "random" {
				check_insecure_random_call(ctx, call, mod, func_name)

				// Check if target has a security-relevant name
				for target in s.targets {
					if name, n_ok := target.(^parser.Name_Expr); n_ok {
						if is_security_name(name.id) {
							append(&ctx.diagnostics, core.Diagnostic{
								severity = .Security,
								location = core.Location{
									file   = ctx.file_path,
									line   = int(call.loc.line),
									column = int(call.loc.col),
								},
								what = fmt.tprintf("insecure random used for security-sensitive value '%s'", name.id),
								why  = "the 'random' module uses a predictable PRNG not suitable for security",
								fix  = "use secrets.token_hex(), secrets.token_urlsafe(), or secrets.token_bytes()",
								code = "SEC002",
							})
						}
					}
				}
			}
		}
	case ^parser.Aug_Assign:
		// x += random.randint(...)
		if call, ok := s.value.(^parser.Call_Expr); ok {
			mod, func_name := resolve_call(ctx, call)
			if mod == "random" {
				check_insecure_random_call(ctx, call, mod, func_name)
			}
		}
	case ^parser.Return_Stmt:
		// return random.choice(...)
		if s.value != nil {
			if call, ok := s.value.(^parser.Call_Expr); ok {
				mod, func_name := resolve_call(ctx, call)
				if mod == "random" {
					check_insecure_random_call(ctx, call, mod, func_name)
				}
			}
		}
	case ^parser.Func_Def:
		for st in s.body { walk_assign_random(ctx, st) }
	case ^parser.Async_Func_Def:
		for st in s.body { walk_assign_random(ctx, st) }
	case ^parser.Class_Def:
		for st in s.body { walk_assign_random(ctx, st) }
	case ^parser.If_Stmt:
		for st in s.body { walk_assign_random(ctx, st) }
		for st in s.orelse { walk_assign_random(ctx, st) }
	case ^parser.For_Stmt:
		for st in s.body { walk_assign_random(ctx, st) }
		for st in s.orelse { walk_assign_random(ctx, st) }
	case ^parser.While_Stmt:
		for st in s.body { walk_assign_random(ctx, st) }
		for st in s.orelse { walk_assign_random(ctx, st) }
	case ^parser.With_Stmt:
		for st in s.body { walk_assign_random(ctx, st) }
	case ^parser.Try_Stmt:
		for st in s.body { walk_assign_random(ctx, st) }
		for h in s.handlers { for st in h.body { walk_assign_random(ctx, st) } }
		for st in s.orelse { walk_assign_random(ctx, st) }
		for st in s.finalbody { walk_assign_random(ctx, st) }
	}
}

// Helper: check if a random.* call uses an insecure function (for SEC002 in non-assign contexts)
check_insecure_random_call :: proc(ctx: ^Security_Context, call: ^parser.Call_Expr, mod, func_name: string) {
	insecure_funcs := [?]string{"choice", "choices", "randint", "random", "getrandbits", "uniform", "randrange"}
	for f in insecure_funcs {
		if func_name == f {
			append(&ctx.diagnostics, core.Diagnostic{
				severity = .Security,
				location = core.Location{
					file   = ctx.file_path,
					line   = int(call.loc.line),
					column = int(call.loc.col),
				},
				what = fmt.tprintf("insecure random function '%s.%s()' used", mod, func_name),
				why  = "the 'random' module uses a predictable PRNG not suitable for security",
				fix  = "use secrets.token_hex(), secrets.token_urlsafe(), or secrets.token_bytes()",
				code = "SEC002",
			})
			return
		}
	}
}

// SEC003 — Timing attack (== comparison on secrets)
check_timing_attack :: proc(ctx: ^Security_Context) {
	walk_stmts(ctx, ctx.module.body, proc(ctx: ^Security_Context, expr: parser.Expr) {
		cmp, ok := expr.(^parser.Compare_Expr)
		if !ok { return }

		// Check for == or != operators
		has_eq := false
		for op in cmp.ops {
			if op == .Eq || op == .Not_Eq {
				has_eq = true
				break
			}
		}
		if !has_eq { return }

		// Check if any operand has a security-relevant name
		security_keywords := [?]string{
			"token", "secret", "password", "passwd", "hash",
			"digest", "signature", "key", "api_key", "apikey",
			"mac", "hmac",
		}

		check_name :: proc(name: string, keywords: []string) -> bool {
			lower := strings.to_lower(name, context.temp_allocator)
			for kw in keywords {
				if strings.contains(lower, kw) { return true }
			}
			return false
		}

		found := false
		if name, n_ok := cmp.left.(^parser.Name_Expr); n_ok {
			if check_name(name.id, security_keywords[:]) { found = true }
		}
		if !found {
			for comp in cmp.comparators {
				if name, n_ok := comp.(^parser.Name_Expr); n_ok {
					if check_name(name.id, security_keywords[:]) { found = true; break }
				}
			}
		}

		if found {
			append(&ctx.diagnostics, core.Diagnostic{
				severity = .Security,
				location = core.Location{
					file   = ctx.file_path,
					line   = int(cmp.loc.line),
					column = int(cmp.loc.col),
				},
				what = "string comparison of secret is vulnerable to timing attacks",
				why  = "== comparison leaks information about the secret through execution time differences",
				fix  = "use hmac.compare_digest() for constant-time comparison",
				code = "SEC003",
			})
		}
	})
}
