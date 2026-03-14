package taint

import parser "mimir:parser"

// Sink_Info describes a dangerous sink that requires trusted input.
Sink_Info :: struct {
	arg_index: int,     // which positional arg must be trusted (0-based)
	desc:      string,  // human description
	code:      string,  // SEC0xx rule code
}

// check_sink determines if a Call_Expr is a dangerous sink.
// Returns sink info if it is, with the argument index to check.
check_sink :: proc(ctx: ^Taint_Context, call: ^parser.Call_Expr) -> (is_sink: bool, info: Sink_Info) {
	#partial switch f in call.func {
	case ^parser.Name_Expr:
		// Resolve aliases: e = eval → resolve "e" to ("", "eval")
		name := f.id
		mod := ""
		if alias, ok := ctx.name_aliases[name]; ok {
			name = alias.name
			mod = alias.module
		} else if m, ok := ctx.import_map[f.id]; ok {
			mod = m
		}

		// Builtin sinks
		if mod == "" || mod == "builtins" {
			if name == "eval" { return true, {arg_index = 0, desc = "eval()", code = "SEC010"} }
			if name == "exec" { return true, {arg_index = 0, desc = "exec()", code = "SEC011"} }
			if name == "open" { return true, {arg_index = 0, desc = "open()", code = "SEC014"} }
		}

		// Module-qualified sinks via from-import or alias
		if mod == "os" && name == "system" {
			return true, {arg_index = 0, desc = "os.system()", code = "SEC013"}
		}
		if mod == "subprocess" && (name == "run" || name == "call" || name == "Popen") {
			if has_shell_true(call) {
				return true, {arg_index = 0, desc = "subprocess with shell=True", code = "SEC013"}
			}
		}

	case ^parser.Attribute_Expr:
		if name, ok := f.value.(^parser.Name_Expr); ok {
			if mod, ok2 := ctx.import_map[name.id]; ok2 {
				// os.system(x) — SEC013
				if mod == "os" && f.attr == "system" {
					return true, {arg_index = 0, desc = "os.system()", code = "SEC013"}
				}
				// subprocess.run(x, shell=True), subprocess.call, subprocess.Popen
				if mod == "subprocess" && (f.attr == "run" || f.attr == "call" || f.attr == "Popen") {
					if has_shell_true(call) {
						return true, {arg_index = 0, desc = "subprocess with shell=True", code = "SEC013"}
					}
				}
			}
			// cursor.execute(x) — SEC012
			// Heuristic: any .execute() call is treated as potential SQL sink
			// Even with parameterized queries, the query string itself should not be tainted
			if f.attr == "execute" {
				return true, {arg_index = 0, desc = "SQL execute()", code = "SEC012"}
			}
		}
	}

	return false, {}
}

// is_sanitizer checks if a Call_Expr sanitizes tainted data.
// Type-casting builtins convert tainted data to safe values.
is_sanitizer :: proc(ctx: ^Taint_Context, call: ^parser.Call_Expr) -> bool {
	#partial switch f in call.func {
	case ^parser.Name_Expr:
		switch f.id {
		case "int", "float", "bool", "bytes", "chr", "ord":
			return true
		}
		// os.path.basename via from import
		if mod, ok := ctx.import_map[f.id]; ok {
			if mod == "os.path" && f.id == "basename" { return true }
		}
	case ^parser.Attribute_Expr:
		// os.path.basename(x)
		if inner, ok := f.value.(^parser.Attribute_Expr); ok {
			if name, ok2 := inner.value.(^parser.Name_Expr); ok2 {
				if mod, ok3 := ctx.import_map[name.id]; ok3 {
					if mod == "os" && inner.attr == "path" && f.attr == "basename" {
						return true
					}
				}
			}
		}
	}
	return false
}

// has_shell_true checks if a Call_Expr has a shell=True keyword argument.
has_shell_true :: proc(call: ^parser.Call_Expr) -> bool {
	for kw in call.keywords {
		if kw.arg == "shell" {
			if c, ok := kw.value.(^parser.Constant_Expr); ok {
				if v, ok2 := c.value.(bool); ok2 && v {
					return true
				}
			}
		}
	}
	return false
}
