package taint

import "core:mem"
import parser "mimir:parser"
import binder "mimir:binder"
import core "mimir:core"

// ==================== Expression Taint ====================

// expr_taint evaluates the taint label of an expression given the current taint environment.
expr_taint :: proc(ctx: ^Taint_Context, env: ^Taint_Env, expr: parser.Expr) -> Taint_Info {
	if expr == nil { return {label = .Trusted} }

	#partial switch e in expr {
	case ^parser.Name_Expr:
		sym_id, ok := binder.get_ref(ctx.bind_result, rawptr(e))
		if ok {
			if info, found := env.info[sym_id]; found {
				return info
			}
		}
		return {label = .Unknown}

	case ^parser.Constant_Expr:
		return {label = .Trusted}

	case ^parser.Call_Expr:
		// Check if source
		is_src, desc := check_source(ctx, parser.Expr(e))
		if is_src {
			return {label = .Untrusted, source_loc = e.loc, source_desc = desc}
		}
		// Check if sanitizer
		if is_sanitizer(ctx, e) {
			return {label = .Trusted}
		}
		// Method call on tainted object: propagate taint
		if attr, ok := e.func.(^parser.Attribute_Expr); ok {
			return expr_taint(ctx, env, attr.value)
		}
		// Cross-function summary lookup for direct Name_Expr calls
		if ctx.summaries != nil {
			if name, is_name := e.func.(^parser.Name_Expr); is_name {
				if summary, found := ctx.summaries[name.id]; found {
					if summary.always_tainted {
						return {label = .Untrusted, source_loc = summary.source_loc, source_desc = summary.source_desc}
					}
					if summary.propagates {
						for arg in e.args {
							arg_info := expr_taint(ctx, env, arg)
							if arg_info.label == .Untrusted {
								return arg_info
							}
						}
						return {label = .Trusted}
					}
					return {label = .Trusted}  // known function, no taint propagation
				}
			}
		}
		// Unknown function call — propagate taint from arguments conservatively
		max_arg := Taint_Info{label = .Trusted}
		for arg in e.args {
			arg_info := expr_taint(ctx, env, arg)
			max_arg = max_taint_info(max_arg, arg_info)
		}
		for kw in e.keywords {
			kw_info := expr_taint(ctx, env, kw.value)
			max_arg = max_taint_info(max_arg, kw_info)
		}
		return max_arg

	case ^parser.Bin_Op_Expr:
		left := expr_taint(ctx, env, e.left)
		right := expr_taint(ctx, env, e.right)
		return max_taint_info(left, right)

	case ^parser.Joined_Str:
		result := Taint_Info{label = .Trusted}
		for v in e.values {
			result = max_taint_info(result, expr_taint(ctx, env, v))
		}
		return result

	case ^parser.Formatted_Value:
		return expr_taint(ctx, env, e.value)

	case ^parser.Attribute_Expr:
		// Check if source pattern (request.args, etc.)
		is_src, desc := check_source(ctx, parser.Expr(e))
		if is_src {
			return {label = .Untrusted, source_loc = e.loc, source_desc = desc}
		}
		return expr_taint(ctx, env, e.value)

	case ^parser.Subscript_Expr:
		// Check if source pattern (sys.argv[...], os.environ[...])
		is_src, desc := check_source(ctx, parser.Expr(e))
		if is_src {
			return {label = .Untrusted, source_loc = e.loc, source_desc = desc}
		}
		return expr_taint(ctx, env, e.value)

	case ^parser.If_Expr:
		body := expr_taint(ctx, env, e.body)
		orelse := expr_taint(ctx, env, e.orelse)
		return max_taint_info(body, orelse)

	case ^parser.Bool_Op_Expr:
		result := Taint_Info{label = .Trusted}
		for v in e.values {
			result = max_taint_info(result, expr_taint(ctx, env, v))
		}
		return result

	case ^parser.Unary_Op_Expr:
		return expr_taint(ctx, env, e.operand)

	case ^parser.List_Expr:
		result := Taint_Info{label = .Trusted}
		for elt in e.elts {
			result = max_taint_info(result, expr_taint(ctx, env, elt))
		}
		return result

	case ^parser.Dict_Expr:
		result := Taint_Info{label = .Trusted}
		for key in e.keys {
			result = max_taint_info(result, expr_taint(ctx, env, key))
		}
		for val in e.values {
			result = max_taint_info(result, expr_taint(ctx, env, val))
		}
		return result

	case ^parser.Set_Expr:
		result := Taint_Info{label = .Trusted}
		for elt in e.elts {
			result = max_taint_info(result, expr_taint(ctx, env, elt))
		}
		return result

	case ^parser.Tuple_Expr:
		result := Taint_Info{label = .Trusted}
		for elt in e.elts {
			result = max_taint_info(result, expr_taint(ctx, env, elt))
		}
		return result

	case ^parser.Named_Expr:
		val_taint := expr_taint(ctx, env, e.value)
		assign_taint(ctx, env, e.target, val_taint)
		return val_taint

	case ^parser.List_Comp:
		for gen in e.generators {
			iter_taint := expr_taint(ctx, env, gen.iter)
			assign_taint(ctx, env, gen.target, iter_taint)
		}
		return expr_taint(ctx, env, e.elt)

	case ^parser.Set_Comp:
		for gen in e.generators {
			iter_taint := expr_taint(ctx, env, gen.iter)
			assign_taint(ctx, env, gen.target, iter_taint)
		}
		return expr_taint(ctx, env, e.elt)

	case ^parser.Generator_Expr:
		for gen in e.generators {
			iter_taint := expr_taint(ctx, env, gen.iter)
			assign_taint(ctx, env, gen.target, iter_taint)
		}
		return expr_taint(ctx, env, e.elt)

	case ^parser.Dict_Comp:
		for gen in e.generators {
			iter_taint := expr_taint(ctx, env, gen.iter)
			assign_taint(ctx, env, gen.target, iter_taint)
		}
		key_taint := expr_taint(ctx, env, e.key)
		val_taint := expr_taint(ctx, env, e.value)
		return max_taint_info(key_taint, val_taint)
	}

	return {label = .Unknown}
}

// ==================== Statement Processing ====================

// process_stmt updates the taint environment and checks for sink violations.
process_stmt :: proc(ctx: ^Taint_Context, env: ^Taint_Env, stmt: parser.Stmt) {
	#partial switch s in stmt {
	case ^parser.Assign:
		info := expr_taint(ctx, env, s.value)
		// Assign taint to all targets
		for target in s.targets {
			assign_taint(ctx, env, target, info)
		}
		// Check for sinks in the value expression
		check_expr_sinks(ctx, env, s.value)

	case ^parser.Aug_Assign:
		current := expr_taint(ctx, env, s.target)
		value := expr_taint(ctx, env, s.value)
		combined := max_taint_info(current, value)
		assign_taint(ctx, env, s.target, combined)
		check_expr_sinks(ctx, env, s.value)

	case ^parser.Ann_Assign:
		if s.value != nil {
			info := expr_taint(ctx, env, s.value)
			assign_taint(ctx, env, s.target, info)
			check_expr_sinks(ctx, env, s.value)
		}

	case ^parser.Expr_Stmt:
		check_expr_sinks(ctx, env, s.value)

	case ^parser.Return_Stmt:
		if s.value != nil {
			check_expr_sinks(ctx, env, s.value)
		}
	}
}

// assign_taint records taint info for the target expression (typically a Name_Expr).
assign_taint :: proc(ctx: ^Taint_Context, env: ^Taint_Env, target: parser.Expr, info: Taint_Info) {
	if target == nil { return }
	#partial switch t in target {
	case ^parser.Name_Expr:
		sym_id, ok := binder.get_ref(ctx.bind_result, rawptr(t))
		if ok {
			env.info[sym_id] = info
		}
	case ^parser.Tuple_Expr:
		// Tuple unpacking: propagate same taint to all elements
		for elt in t.elts {
			assign_taint(ctx, env, elt, info)
		}
	case ^parser.List_Expr:
		for elt in t.elts {
			assign_taint(ctx, env, elt, info)
		}
	case ^parser.Named_Expr:
		assign_taint(ctx, env, t.target, info)
	case ^parser.Attribute_Expr:
		// obj.attr = tainted → propagate taint to the base object
		assign_taint(ctx, env, t.value, info)
	case ^parser.Subscript_Expr:
		// container[key] = tainted → propagate taint to the container
		assign_taint(ctx, env, t.value, info)
	}
}

// ==================== Sink Checking ====================

// Wrapper context for the sink-checking walker.
Sink_Walker :: struct {
	taint_ctx: ^Taint_Context,
	env:       ^Taint_Env,
}

// check_expr_sinks walks an expression tree looking for
// Call_Exprs that are sinks and checks if their arguments are tainted.
// Uses the shared core.AST_Visitor for traversal.
check_expr_sinks :: proc(ctx: ^Taint_Context, env: ^Taint_Env, expr: parser.Expr) {
	if expr == nil { return }

	sw := Sink_Walker{taint_ctx = ctx, env = env}
	visitor := core.AST_Visitor{
		visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
			w := cast(^Sink_Walker)raw_ctx
			e, ok := expr.(^parser.Call_Expr)
			if !ok { return }

			is_sink, info := check_sink(w.taint_ctx, e)
			if !is_sink { return }

			// Check positional args
			if info.arg_index < len(e.args) {
				arg_info := expr_taint(w.taint_ctx, w.env, e.args[info.arg_index])
				if arg_info.label == .Untrusted {
					append(&w.taint_ctx.violations, Taint_Violation{
						sink_loc    = e.loc,
						source_loc  = arg_info.source_loc,
						source_desc = arg_info.source_desc,
						sink_desc   = info.desc,
						rule_code   = info.code,
					})
				}
			}
			// Also check keyword args for taint
			for kw in e.keywords {
				kw_info := expr_taint(w.taint_ctx, w.env, kw.value)
				if kw_info.label == .Untrusted {
					append(&w.taint_ctx.violations, Taint_Violation{
						sink_loc    = e.loc,
						source_loc  = kw_info.source_loc,
						source_desc = kw_info.source_desc,
						sink_desc   = info.desc,
						rule_code   = info.code,
					})
					break // one violation per call is enough
				}
			}
		},
		ctx = rawptr(&sw),
	}
	core.walk_expr(&visitor, expr)
}

// ==================== Environment Merge ====================

// merge_taint_envs merges source env into destination at CFG join points.
// Uses max(label_a, label_b) — if ANY predecessor is Untrusted, result is Untrusted.
merge_taint_envs :: proc(dst: ^Taint_Env, src: ^Taint_Env, allocator: mem.Allocator) {
	for sym_id, src_info in src.info {
		if dst_info, ok := dst.info[sym_id]; ok {
			dst.info[sym_id] = max_taint_info(dst_info, src_info)
		} else {
			dst.info[sym_id] = src_info
		}
	}
}
