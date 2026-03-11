package security

import "core:fmt"
import "core:strings"
import parser "mimir:parser"
import core "mimir:core"

// SEC006 — eval/exec usage
check_eval_exec :: proc(ctx: ^Security_Context) {
	walk_stmts(ctx, ctx.module.body, proc(ctx: ^Security_Context, expr: parser.Expr) {
		call, ok := expr.(^parser.Call_Expr)
		if !ok { return }

		func_name := ""
		#partial switch f in call.func {
		case ^parser.Name_Expr:
			if f.id == "eval" || f.id == "exec" {
				func_name = f.id
			}
		case ^parser.Attribute_Expr:
			// builtins.eval / builtins.exec
			if name, n_ok := f.value.(^parser.Name_Expr); n_ok {
				if name.id == "builtins" && (f.attr == "eval" || f.attr == "exec") {
					func_name = f.attr
				}
			}
		}

		if func_name != "" {
			append(&ctx.diagnostics, core.Diagnostic{
				severity = .Security,
				location = core.Location{
					file   = ctx.file_path,
					line   = int(call.loc.line),
					column = int(call.loc.col),
				},
				what = fmt.tprintf("%s() can execute arbitrary code", func_name),
				why  = "dynamic code execution allows injection of malicious code",
				fix  = "use ast.literal_eval() for safe evaluation, or avoid dynamic code execution",
				code = "SEC006",
			})
		}
	})
}

// SEC007 — Unsafe deserialization (pickle, yaml.load)
check_unsafe_deserialization :: proc(ctx: ^Security_Context) {
	walk_stmts(ctx, ctx.module.body, proc(ctx: ^Security_Context, expr: parser.Expr) {
		call, ok := expr.(^parser.Call_Expr)
		if !ok { return }

		mod, func_name := resolve_call(ctx, call)

		// pickle.loads / pickle.load
		if mod == "pickle" && (func_name == "loads" || func_name == "load") {
			append(&ctx.diagnostics, core.Diagnostic{
				severity = .Security,
				location = core.Location{
					file   = ctx.file_path,
					line   = int(call.loc.line),
					column = int(call.loc.col),
				},
				what = fmt.tprintf("pickle.%s() can execute arbitrary code during deserialization", func_name),
				why  = "unpickling untrusted data can execute arbitrary Python code",
				fix  = "use json.loads() or a safe serialization format",
				code = "SEC007",
			})
			return
		}

		// yaml.load without SafeLoader
		if mod == "yaml" && func_name == "load" {
			// Check if Loader kwarg is present and safe
			has_safe_loader := false
			for kw in call.keywords {
				if kw.arg == "Loader" {
					// Check if value mentions "Safe"
					if name, n_ok := kw.value.(^parser.Name_Expr); n_ok {
						if strings.contains(name.id, "Safe") {
							has_safe_loader = true
						}
					} else if attr, a_ok := kw.value.(^parser.Attribute_Expr); a_ok {
						if strings.contains(attr.attr, "Safe") {
							has_safe_loader = true
						}
					}
				}
			}

			if !has_safe_loader {
				append(&ctx.diagnostics, core.Diagnostic{
					severity = .Security,
					location = core.Location{
						file   = ctx.file_path,
						line   = int(call.loc.line),
						column = int(call.loc.col),
					},
					what = "yaml.load() without SafeLoader can execute arbitrary code",
					why  = "the default YAML loader can instantiate arbitrary Python objects",
					fix  = "use yaml.safe_load() or pass Loader=yaml.SafeLoader",
					code = "SEC007",
				})
			}
		}
	})
}

// SEC008 — Shell injection risk
check_shell_injection :: proc(ctx: ^Security_Context) {
	walk_stmts(ctx, ctx.module.body, proc(ctx: ^Security_Context, expr: parser.Expr) {
		call, ok := expr.(^parser.Call_Expr)
		if !ok { return }

		mod, func_name := resolve_call(ctx, call)

		// os.system / os.popen — always dangerous
		if mod == "os" && (func_name == "system" || func_name == "popen") {
			append(&ctx.diagnostics, core.Diagnostic{
				severity = .Security,
				location = core.Location{
					file   = ctx.file_path,
					line   = int(call.loc.line),
					column = int(call.loc.col),
				},
				what = fmt.tprintf("os.%s() executes commands through the shell", func_name),
				why  = "shell execution with user-controllable input enables command injection",
				fix  = "use subprocess.run() with a list of arguments instead",
				code = "SEC008",
			})
			return
		}

		// subprocess.run/call/Popen with shell=True
		if mod == "subprocess" && (func_name == "run" || func_name == "call" || func_name == "Popen" || func_name == "check_output" || func_name == "check_call") {
			for kw in call.keywords {
				if kw.arg == "shell" {
					if c, c_ok := kw.value.(^parser.Constant_Expr); c_ok {
						if b, b_ok := c.value.(bool); b_ok && b {
							append(&ctx.diagnostics, core.Diagnostic{
								severity = .Security,
								location = core.Location{
									file   = ctx.file_path,
									line   = int(call.loc.line),
									column = int(call.loc.col),
								},
								what = fmt.tprintf("subprocess.%s() with shell=True enables command injection", func_name),
								why  = "shell=True passes the command through the system shell, enabling injection",
								fix  = "use subprocess.run() with a list of arguments and remove shell=True",
								code = "SEC008",
							})
						}
					}
				}
			}
		}
	})
}
