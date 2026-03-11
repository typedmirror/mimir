package security

import "core:fmt"
import "core:strings"
import parser "mimir:parser"
import core "mimir:core"

// SEC004 — Hardcoded secret
check_hardcoded_secret :: proc(ctx: ^Security_Context) {
	// Walk all statements looking for assignments with secret names + string values,
	// and for string constants matching known API key prefixes.
	walk_stmts_for_secrets(ctx, ctx.module.body)
}

walk_stmts_for_secrets :: proc(ctx: ^Security_Context, stmts: []parser.Stmt) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Assign:
			// Check: secret_name = "string_value"
			if c, ok := s.value.(^parser.Constant_Expr); ok {
				if str, s_ok := c.value.(string); s_ok {
					if len(str) > 8 {
						for target in s.targets {
							if name, n_ok := target.(^parser.Name_Expr); n_ok {
								if is_secret_variable_name(name.id) {
									append(&ctx.diagnostics, core.Diagnostic{
										severity = .Security,
										location = core.Location{
											file   = ctx.file_path,
											line   = int(s.loc.line),
											column = int(s.loc.col),
										},
										what = fmt.tprintf("hardcoded secret in variable '%s'", name.id),
										why  = "hardcoded secrets can be extracted from source code or version control",
										fix  = "use environment variables or a secrets manager",
										code = "SEC004",
									})
								}
							}
						}
					}
				}
			}

			// Also check string values for known prefixes regardless of variable name
			check_string_prefixes(ctx, s.value, s.loc)

		case ^parser.Ann_Assign:
			if s.value != nil {
				if c, ok := s.value.(^parser.Constant_Expr); ok {
					if str, s_ok := c.value.(string); s_ok {
						if len(str) > 8 {
							if name, n_ok := s.target.(^parser.Name_Expr); n_ok {
								if is_secret_variable_name(name.id) {
									append(&ctx.diagnostics, core.Diagnostic{
										severity = .Security,
										location = core.Location{
											file   = ctx.file_path,
											line   = int(s.loc.line),
											column = int(s.loc.col),
										},
										what = fmt.tprintf("hardcoded secret in variable '%s'", name.id),
										why  = "hardcoded secrets can be extracted from source code or version control",
										fix  = "use environment variables or a secrets manager",
										code = "SEC004",
									})
								}
							}
						}
					}
				}
				check_string_prefixes(ctx, s.value, s.loc)
			}

		case ^parser.Func_Def:
			walk_stmts_for_secrets(ctx, s.body)
		case ^parser.Async_Func_Def:
			walk_stmts_for_secrets(ctx, s.body)
		case ^parser.Class_Def:
			walk_stmts_for_secrets(ctx, s.body)
		case ^parser.If_Stmt:
			walk_stmts_for_secrets(ctx, s.body)
			walk_stmts_for_secrets(ctx, s.orelse)
		case ^parser.For_Stmt:
			walk_stmts_for_secrets(ctx, s.body)
			walk_stmts_for_secrets(ctx, s.orelse)
		case ^parser.While_Stmt:
			walk_stmts_for_secrets(ctx, s.body)
			walk_stmts_for_secrets(ctx, s.orelse)
		case ^parser.With_Stmt:
			walk_stmts_for_secrets(ctx, s.body)
		case ^parser.Try_Stmt:
			walk_stmts_for_secrets(ctx, s.body)
			for h in s.handlers { walk_stmts_for_secrets(ctx, h.body) }
			walk_stmts_for_secrets(ctx, s.orelse)
			walk_stmts_for_secrets(ctx, s.finalbody)
		}
	}
}

// Check string constants for known API key prefixes
check_string_prefixes :: proc(ctx: ^Security_Context, expr: parser.Expr, stmt_loc: parser.Src_Loc) {
	c, ok := expr.(^parser.Constant_Expr)
	if !ok { return }
	str, s_ok := c.value.(string)
	if !s_ok { return }
	if len(str) <= 8 { return }

	// Known prefixes for API keys/tokens
	prefixes := [?]struct{prefix: string, desc: string}{
		{"sk-",   "OpenAI API key"},
		{"ghp_",  "GitHub personal access token"},
		{"gho_",  "GitHub OAuth token"},
		{"ghs_",  "GitHub server-to-server token"},
		{"AKIA",  "AWS access key"},
		{"eyJ",   "JWT token"},
		{"xoxb-", "Slack bot token"},
		{"xoxp-", "Slack user token"},
		{"xoxs-", "Slack session token"},
	}

	for p in prefixes {
		if strings.has_prefix(str, p.prefix) {
			append(&ctx.diagnostics, core.Diagnostic{
				severity = .Security,
				location = core.Location{
					file   = ctx.file_path,
					line   = int(c.loc.line),
					column = int(c.loc.col),
				},
				what = fmt.tprintf("possible %s detected in string literal", p.desc),
				why  = "hardcoded secrets can be extracted from source code or version control",
				fix  = "use environment variables or a secrets manager",
				code = "SEC004",
			})
			return // Only report once per string
		}
	}
}

is_secret_variable_name :: proc(name: string) -> bool {
	lower := strings.to_lower(name, context.temp_allocator)
	patterns := [?]string{
		"api_key", "apikey", "secret_key", "secretkey",
		"auth_token", "access_token", "private_key", "privatekey",
		"secret", "password", "passwd",
	}
	for p in patterns {
		if lower == p { return true }
		if strings.has_suffix(lower, fmt.tprintf("_%s", p)) { return true }
	}
	return false
}

// SEC005 — Embedded credentials in connection strings
check_embedded_credentials :: proc(ctx: ^Security_Context) {
	walk_stmts(ctx, ctx.module.body, proc(ctx: ^Security_Context, expr: parser.Expr) {
		c, ok := expr.(^parser.Constant_Expr)
		if !ok { return }
		str, s_ok := c.value.(string)
		if !s_ok { return }

		// Check for connection string patterns: scheme://user:password@host
		schemes := [?]string{
			"postgresql://", "postgres://",
			"mysql://", "mysql+pymysql://",
			"mongodb://", "mongodb+srv://",
			"redis://", "rediss://",
			"amqp://", "amqps://",
		}

		for scheme in schemes {
			if !strings.has_prefix(str, scheme) { continue }

			rest := str[len(scheme):]
			// Look for user:password@host pattern
			at_idx := strings.index(rest, "@")
			if at_idx < 0 { continue }

			userinfo := rest[:at_idx]
			colon_idx := strings.index(userinfo, ":")
			if colon_idx < 0 { continue }

			password := userinfo[colon_idx + 1:]
			if len(password) == 0 { continue }

			append(&ctx.diagnostics, core.Diagnostic{
				severity = .Security,
				location = core.Location{
					file   = ctx.file_path,
					line   = int(c.loc.line),
					column = int(c.loc.col),
				},
				what = "credentials embedded in connection string",
				why  = "connection strings with inline passwords expose credentials in source code",
				fix  = "use environment variables, e.g. os.environ['DATABASE_URL']",
				code = "SEC005",
			})
			return
		}
	})
}
