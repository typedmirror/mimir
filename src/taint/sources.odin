package taint

import parser "mimir:parser"

// check_source determines if an expression produces tainted (Untrusted) data.
// Returns (true, description) if the expression is a taint source.
check_source :: proc(ctx: ^Taint_Context, expr: parser.Expr) -> (is_source: bool, desc: string) {
	if expr == nil { return false, "" }

	#partial switch e in expr {
	case ^parser.Call_Expr:
		return check_call_source(ctx, e)

	case ^parser.Attribute_Expr:
		// request.args, request.form, request.json, request.data, request.values
		if name, ok := e.value.(^parser.Name_Expr); ok {
			if name.id == "request" || name.id == "req" {
				switch e.attr {
				case "args", "form", "json", "data", "values", "headers", "cookies":
					return true, "request data"
				}
			}
		}

	case ^parser.Subscript_Expr:
		// sys.argv[...], os.environ[...]
		if attr, ok := e.value.(^parser.Attribute_Expr); ok {
			if name, ok2 := attr.value.(^parser.Name_Expr); ok2 {
				if mod, ok3 := ctx.import_map[name.id]; ok3 {
					if mod == "sys" && attr.attr == "argv" { return true, "sys.argv" }
					if mod == "os" && attr.attr == "environ" { return true, "os.environ" }
				}
			}
		}
	}

	return false, ""
}

// check_call_source checks if a Call_Expr invokes a known taint source.
check_call_source :: proc(ctx: ^Taint_Context, call: ^parser.Call_Expr) -> (bool, string) {
	#partial switch f in call.func {
	case ^parser.Name_Expr:
		// Resolve aliases: i = input → resolve "i" to ("", "input")
		name := f.id
		mod := ""
		if alias, ok := ctx.name_aliases[name]; ok {
			name = alias.name
			mod = alias.module
		} else if m, ok := ctx.import_map[f.id]; ok {
			mod = m
		}

		// input() — builtin, always a source
		if (mod == "" || mod == "builtins") && name == "input" { return true, "input()" }

		// Module-qualified sources via from-import or alias
		if mod == "json" && name == "loads" { return true, "json.loads()" }
		if mod == "yaml" && name == "load" { return true, "yaml.load()" }
		if mod == "yaml" && name == "safe_load" { return false, "" }

	case ^parser.Attribute_Expr:
		if name, ok := f.value.(^parser.Name_Expr); ok {
			if mod, ok2 := ctx.import_map[name.id]; ok2 {
				// json.loads(...)
				if mod == "json" && f.attr == "loads" { return true, "json.loads()" }
				// yaml.load(...)
				if mod == "yaml" && f.attr == "load" { return true, "yaml.load()" }
				// os.environ.get(...)
				if mod == "os" && f.attr == "getenv" { return true, "os.getenv()" }
			}
			// request.args.get(...), req.json(), etc.
			if name.id == "request" || name.id == "req" { return true, "request data" }
		}
		// os.environ.get(...) — nested attribute
		if inner, ok := f.value.(^parser.Attribute_Expr); ok {
			if inner_name, ok2 := inner.value.(^parser.Name_Expr); ok2 {
				if mod, ok3 := ctx.import_map[inner_name.id]; ok3 {
					if mod == "os" && inner.attr == "environ" && f.attr == "get" {
						return true, "os.environ"
					}
				}
			}
		}
	}

	return false, ""
}
