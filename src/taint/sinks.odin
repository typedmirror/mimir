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
		// eval(x) — SEC010
		if f.id == "eval" { return true, {arg_index = 0, desc = "eval()", code = "SEC010"} }
		// exec(x) — SEC011
		if f.id == "exec" { return true, {arg_index = 0, desc = "exec()", code = "SEC011"} }
		// open(x) — SEC014
		if f.id == "open" { return true, {arg_index = 0, desc = "open()", code = "SEC014"} }

		// from os import system → import_map["system"] = "os"
		if mod, ok := ctx.import_map[f.id]; ok {
			if mod == "os" && f.id == "system" {
				return true, {arg_index = 0, desc = "os.system()", code = "SEC013"}
			}
		}
		// from subprocess import run → import_map["run"] = "subprocess"
		if mod, ok := ctx.import_map[f.id]; ok {
			if mod == "subprocess" && (f.id == "run" || f.id == "call" || f.id == "Popen") {
				if has_shell_true(call) {
					return true, {arg_index = 0, desc = "subprocess with shell=True", code = "SEC013"}
				}
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
			if f.attr == "execute" {
				// Parameterized query (≥2 args) is safe
				if len(call.args) >= 2 { return false, {} }
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
