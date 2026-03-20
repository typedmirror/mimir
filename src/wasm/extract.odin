package wasm

import "core:mem"
import "core:fmt"
import "core:strconv"

import parser "mimir:parser"
import binder "mimir:binder"

// WASM Extraction — Python AST → WASM_Module IR.
// Post-order expression traversal emits stack-based instructions.

WASM_Extract_Context :: struct {
	module:       ^WASM_Module,
	current_fn:   ^WASM_Function,
	type_ctx:     ^WASM_Type_Context,
	bind_result:  ^binder.Bind_Result,
	locals_map:   map[string]int,        // variable name → local index
	local_types:  map[string]WASM_Value_Type, // variable name → WASM type
	label_depth:  int,                   // nesting depth for br targets
	func_map:     map[string]int,        // @wasm function name → module func index
	import_map:   map[string]int,        // import name → import index
	global_map:   map[string]int,        // global name → global index
	global_types: map[string]WASM_Value_Type, // global name → WASM type
	// Track memory type parameters for expansion
	param_annotations: map[string]parser.Expr, // param name → annotation
	or_temp_counter:   int,                    // unique temp names for boolean or chains
	wasi:         bool,                  // WASI mode
	allocator:    mem.Allocator,
}

// Main entry: extract WASM module from validated @wasm functions.
extract_wasm_module :: proc(
	py_module: ^parser.Module,
	wasm_funcs: []^parser.Func_Def,
	bind_result: ^binder.Bind_Result,
	type_ctx: ^WASM_Type_Context,
	allocator: mem.Allocator,
	wasi: bool = false,
) -> WASM_Module {
	module := WASM_Module{
		functions     = make([dynamic]WASM_Function, 0, len(wasm_funcs), allocator),
		imports       = make([dynamic]WASM_Import, 0, 8, allocator),
		globals       = make([dynamic]WASM_Global, 0, 8, allocator),
		data_segments = make([dynamic]WASM_Data_Segment, 0, 4, allocator),
		memory_pages  = 1, // 64KB default
		wasi          = wasi,
		allocator     = allocator,
	}

	ctx := WASM_Extract_Context{
		module       = &module,
		type_ctx     = type_ctx,
		bind_result  = bind_result,
		func_map     = make(map[string]int, len(wasm_funcs), allocator),
		import_map   = make(map[string]int, 16, allocator),
		global_map   = make(map[string]int, 8, allocator),
		global_types = make(map[string]WASM_Value_Type, 8, allocator),
		wasi         = wasi,
		allocator    = allocator,
	}

	// Scan module-level assignments for globals
	extract_module_globals(py_module, &ctx)

	// Pre-scan functions for host function imports (math.sin, print, etc.)
	for func in wasm_funcs {
		scan_function_imports(func, &ctx)
	}

	// Build func_map: offset by import count so Call indices are correct
	import_count := len(module.imports)
	for func, idx in wasm_funcs {
		ctx.func_map[func.name] = idx + import_count
	}

	// Extract each function
	for func in wasm_funcs {
		extract_function(func, &ctx)
	}

	return module
}

// Scan module-level statements for constant assignments → WASM globals.
extract_module_globals :: proc(py_module: ^parser.Module, ctx: ^WASM_Extract_Context) {
	for stmt in py_module.body {
		#partial switch s in stmt {
		case ^parser.Assign:
			if len(s.targets) != 1 { continue }
			#partial switch t in s.targets[0] {
			case ^parser.Name_Expr:
				val, vtype, ok := try_constant_value(s.value, ctx)
				if !ok { continue }
				global_idx := len(ctx.module.globals)
				g := WASM_Global{
					name    = t.id,
					type    = vtype,
					mutable = false,
				}
				switch vtype {
				case .I32: g.init_i32 = val.i32_val
				case .I64: g.init_i64 = val.i64_val
				case .F32: g.init_f32 = val.f32_val
				case .F64: g.init_f64 = val.f64_val
				case .Void:
				}
				append(&ctx.module.globals, g)
				ctx.global_map[t.id] = global_idx
				ctx.global_types[t.id] = vtype
			}
		case ^parser.Ann_Assign:
			#partial switch t in s.target {
			case ^parser.Name_Expr:
				if s.value == nil { continue }
				val, vtype, ok := try_constant_value(s.value, ctx)
				if !ok { continue }
				global_idx := len(ctx.module.globals)
				g := WASM_Global{
					name    = t.id,
					type    = vtype,
					mutable = false,
				}
				switch vtype {
				case .I32: g.init_i32 = val.i32_val
				case .I64: g.init_i64 = val.i64_val
				case .F32: g.init_f32 = val.f32_val
				case .F64: g.init_f64 = val.f64_val
				case .Void:
				}
				append(&ctx.module.globals, g)
				ctx.global_map[t.id] = global_idx
				ctx.global_types[t.id] = vtype
			}
		}
	}
}

// Try to extract a constant value from an expression.
try_constant_value :: proc(expr: parser.Expr, ctx: ^WASM_Extract_Context) -> (WASM_Instruction, WASM_Value_Type, bool) {
	if expr == nil { return {}, .Void, false }
	#partial switch e in expr {
	case ^parser.Constant_Expr:
		#partial switch v in e.value {
		case i64:
			if v > i64(max(i32)) || v < i64(min(i32)) {
				return WASM_Instruction{i64_val = v}, .I64, true
			}
			return WASM_Instruction{i32_val = i32(v)}, .I32, true
		case f64:
			return WASM_Instruction{f64_val = f64(v)}, .F64, true
		case bool:
			return WASM_Instruction{i32_val = 1 if v else 0}, .I32, true
		}
	case ^parser.Unary_Op_Expr:
		if e.op == .USub {
			inner, itype, ok := try_constant_value(e.operand, ctx)
			if !ok { return {}, .Void, false }
			switch itype {
			case .I32: return WASM_Instruction{i32_val = -inner.i32_val}, .I32, true
			case .I64: return WASM_Instruction{i64_val = -inner.i64_val}, .I64, true
			case .F32: return WASM_Instruction{f32_val = -inner.f32_val}, .F32, true
			case .F64: return WASM_Instruction{f64_val = -inner.f64_val}, .F64, true
			case .Void:
			}
		}
	}
	return {}, .Void, false
}

// Pre-scan function body for calls that need host imports (math.sin, print, etc.).
scan_function_imports :: proc(func: ^parser.Func_Def, ctx: ^WASM_Extract_Context) {
	for stmt in func.body {
		scan_stmt_imports(stmt, ctx)
	}
}

scan_stmt_imports :: proc(stmt: parser.Stmt, ctx: ^WASM_Extract_Context) {
	#partial switch s in stmt {
	case ^parser.Expr_Stmt:
		if s.value != nil { scan_expr_imports(s.value, ctx) }
	case ^parser.Assign:
		scan_expr_imports(s.value, ctx)
	case ^parser.Ann_Assign:
		if s.value != nil { scan_expr_imports(s.value, ctx) }
	case ^parser.Aug_Assign:
		scan_expr_imports(s.value, ctx)
	case ^parser.Return_Stmt:
		if s.value != nil { scan_expr_imports(s.value, ctx) }
	case ^parser.If_Stmt:
		scan_expr_imports(s.test, ctx)
		for body_stmt in s.body { scan_stmt_imports(body_stmt, ctx) }
		for else_stmt in s.orelse { scan_stmt_imports(else_stmt, ctx) }
	case ^parser.While_Stmt:
		scan_expr_imports(s.test, ctx)
		for body_stmt in s.body { scan_stmt_imports(body_stmt, ctx) }
	case ^parser.For_Stmt:
		scan_expr_imports(s.iter, ctx)
		for body_stmt in s.body { scan_stmt_imports(body_stmt, ctx) }
	}
}

scan_expr_imports :: proc(expr: parser.Expr, ctx: ^WASM_Extract_Context) {
	if expr == nil { return }
	#partial switch e in expr {
	case ^parser.Call_Expr:
		// Check for print() → host import
		#partial switch f in e.func {
		case ^parser.Name_Expr:
			if f.id == "print" {
				register_print_import(ctx)
			}
		case ^parser.Attribute_Expr:
			// math.sin, math.cos, etc.
			#partial switch v in f.value {
			case ^parser.Name_Expr:
				if v.id == "math" {
					register_math_import(f.attr, ctx)
				}
			}
		}
		// Recurse into args
		for arg in e.args { scan_expr_imports(arg, ctx) }
	case ^parser.Bin_Op_Expr:
		scan_expr_imports(e.left, ctx)
		scan_expr_imports(e.right, ctx)
	case ^parser.Unary_Op_Expr:
		scan_expr_imports(e.operand, ctx)
	case ^parser.Compare_Expr:
		scan_expr_imports(e.left, ctx)
		for c in e.comparators { scan_expr_imports(c, ctx) }
	case ^parser.Bool_Op_Expr:
		for v in e.values { scan_expr_imports(v, ctx) }
	case ^parser.If_Expr:
		scan_expr_imports(e.test, ctx)
		scan_expr_imports(e.body, ctx)
		scan_expr_imports(e.orelse, ctx)
	}
}

// Register a print() host import.
register_print_import :: proc(ctx: ^WASM_Extract_Context) {
	if ctx.wasi {
		// WASI: fd_write(fd, iovs, iovs_len, nwritten) → i32
		if _, ok := ctx.import_map["fd_write"]; ok { return }
		idx := len(ctx.module.imports)
		append(&ctx.module.imports, WASM_Import{
			module_name = "wasi_snapshot_preview1",
			field_name  = "fd_write",
			type        = make_func_type(ctx.allocator, {.I32, .I32, .I32, .I32}, {.I32}),
		})
		ctx.import_map["fd_write"] = idx
	} else {
		// Browser: console_log_i32(x), console_log_f64(x)
		if _, ok := ctx.import_map["console_log_i32"]; !ok {
			idx := len(ctx.module.imports)
			append(&ctx.module.imports, WASM_Import{
				module_name = "env",
				field_name  = "console_log_i32",
				type        = make_func_type(ctx.allocator, {.I32}, {}),
			})
			ctx.import_map["console_log_i32"] = idx
		}
		if _, ok := ctx.import_map["console_log_f64"]; !ok {
			idx := len(ctx.module.imports)
			append(&ctx.module.imports, WASM_Import{
				module_name = "env",
				field_name  = "console_log_f64",
				type        = make_func_type(ctx.allocator, {.F64}, {}),
			})
			ctx.import_map["console_log_f64"] = idx
		}
	}
}

// Register a math.X host import.
register_math_import :: proc(attr: string, ctx: ^WASM_Extract_Context) {
	// floor, ceil, sqrt use native WASM instructions — no import needed
	if attr == "floor" || attr == "ceil" || attr == "sqrt" || attr == "trunc" { return }
	if attr == "fabs" || attr == "copysign" { return }

	import_name := fmt.tprintf("math_%s", attr)
	if _, ok := ctx.import_map[import_name]; ok { return }

	idx := len(ctx.module.imports)
	math_type: WASM_Func_Type
	switch attr {
	case "sin", "cos", "tan", "asin", "acos", "atan", "exp", "log", "log2", "log10":
		math_type = make_func_type(ctx.allocator, {.F64}, {.F64})
	case "pow", "atan2", "fmod":
		math_type = make_func_type(ctx.allocator, {.F64, .F64}, {.F64})
	case:
		return // Unknown math function
	}

	append(&ctx.module.imports, WASM_Import{
		module_name = "Math",
		field_name  = attr,
		type        = math_type,
	})
	ctx.import_map[import_name] = idx
}

// Helper: create a WASM_Func_Type with properly allocated slices.
make_func_type :: proc(allocator: mem.Allocator, params: []WASM_Value_Type, results: []WASM_Value_Type) -> WASM_Func_Type {
	p := make([]WASM_Value_Type, len(params), allocator)
	for v, i in params { p[i] = v }
	r := make([]WASM_Value_Type, len(results), allocator)
	for v, i in results { r[i] = v }
	return WASM_Func_Type{params = p, results = r}
}

// Extract a single @wasm function to WASM IR.
extract_function :: proc(func: ^parser.Func_Def, ctx: ^WASM_Extract_Context) {
	wfn := WASM_Function{
		name     = func.name,
		locals   = make([dynamic]WASM_Local, 0, 16, ctx.allocator),
		body     = make([dynamic]WASM_Instruction, 0, 64, ctx.allocator),
		exported = true,
	}

	ctx.current_fn = &wfn
	ctx.locals_map = make(map[string]int, 16, ctx.allocator)
	ctx.local_types = make(map[string]WASM_Value_Type, 16, ctx.allocator)
	ctx.param_annotations = make(map[string]parser.Expr, 16, ctx.allocator)
	ctx.label_depth = 0

	// Build parameter list with memory type expansion
	params := make([dynamic]WASM_Value_Type, 0, len(func.args.args) * 2, ctx.allocator)
	local_idx := 0

	for arg in func.args.args {
		if arg.arg == "self" { continue }

		ctx.param_annotations[arg.arg] = arg.annotation

		if is_memory_type(arg.annotation) {
			// Memory type → expand to (ptr: i32, len: i32)
			ptr_name := fmt.tprintf("%s_ptr", arg.arg)
			len_name := fmt.tprintf("%s_len", arg.arg)
			ctx.locals_map[ptr_name] = local_idx
			ctx.local_types[ptr_name] = .I32
			append(&params, WASM_Value_Type.I32)
			local_idx += 1
			ctx.locals_map[len_name] = local_idx
			ctx.local_types[len_name] = .I32
			append(&params, WASM_Value_Type.I32)
			local_idx += 1
			// Also map the original name to the ptr for convenience
			ctx.locals_map[arg.arg] = ctx.locals_map[ptr_name]
			ctx.local_types[arg.arg] = .I32
		} else {
			wtype := python_type_to_wasm(arg.annotation, ctx.type_ctx)
			if wtype == .Void { wtype = .I32 } // default
			ctx.locals_map[arg.arg] = local_idx
			ctx.local_types[arg.arg] = wtype
			append(&params, wtype)
			local_idx += 1
		}
	}

	// Build result type
	results := make([dynamic]WASM_Value_Type, 0, 1, ctx.allocator)
	if func.returns != nil {
		if is_memory_type(func.returns) {
			// Memory return → i32 (pointer to output buffer)
			append(&results, WASM_Value_Type.I32)
		} else {
			rtype := python_type_to_wasm(func.returns, ctx.type_ctx)
			if rtype != .Void {
				append(&results, rtype)
			}
		}
	}

	wfn.type = WASM_Func_Type{
		params  = params[:],
		results = results[:],
	}

	// Extract body statements
	for stmt in func.body {
		extract_stmt(stmt, ctx)
	}

	append(&ctx.module.functions, wfn)
}

// Allocate a new local variable, returns its index.
alloc_local :: proc(ctx: ^WASM_Extract_Context, name: string, type: WASM_Value_Type) -> int {
	// Count params + existing locals
	idx := len(ctx.current_fn.type.params) + len(ctx.current_fn.locals)
	append(&ctx.current_fn.locals, WASM_Local{name = name, type = type})
	ctx.locals_map[name] = idx
	ctx.local_types[name] = type
	return idx
}

// Emit a single instruction.
emit :: proc(ctx: ^WASM_Extract_Context, instr: WASM_Instruction) {
	append(&ctx.current_fn.body, instr)
}

// === Statement extraction ===

extract_stmt :: proc(stmt: parser.Stmt, ctx: ^WASM_Extract_Context) {
	#partial switch s in stmt {
	case ^parser.Assign:
		extract_assign(s, ctx)
	case ^parser.Ann_Assign:
		extract_ann_assign(s, ctx)
	case ^parser.Aug_Assign:
		extract_aug_assign(s, ctx)
	case ^parser.If_Stmt:
		extract_if_stmt(s, ctx)
	case ^parser.While_Stmt:
		extract_while_stmt(s, ctx)
	case ^parser.For_Stmt:
		extract_for_stmt(s, ctx)
	case ^parser.Return_Stmt:
		extract_return_stmt(s, ctx)
	case ^parser.Expr_Stmt:
		// Only emit Drop if the expression pushes a value onto the stack
		if s.value != nil {
			#partial switch _ in s.value {
			case ^parser.Call_Expr:
				extract_expr(s.value, ctx)
				emit(ctx, WASM_Instruction{kind = .Drop})
			case:
				extract_expr(s.value, ctx)
			}
		}
	case ^parser.Pass_Stmt:
		// nop
	case ^parser.Break_Stmt:
		// br to enclosing block (label_depth 1 = break target)
		emit(ctx, WASM_Instruction{kind = .Br, label_idx = 1})
	case ^parser.Continue_Stmt:
		// br to enclosing loop (label_depth 0 = loop start)
		emit(ctx, WASM_Instruction{kind = .Br, label_idx = 0})
	}
}

extract_assign :: proc(s: ^parser.Assign, ctx: ^WASM_Extract_Context) {
	if len(s.targets) == 0 { return }

	// Evaluate value once
	extract_expr(s.value, ctx)
	val_type := infer_expr_type(s.value, ctx)

	// Store to each target (use Local_Tee for all but last to keep value on stack)
	for target, ti in s.targets {
		#partial switch t in target {
		case ^parser.Name_Expr:
			idx, ok := ctx.locals_map[t.id]
			if !ok {
				idx = alloc_local(ctx, t.id, val_type)
			} else {
				local_type := ctx.local_types[t.id]
				if val_type != local_type {
					emit_conversion(ctx, val_type, local_type)
				}
			}
			if ti < len(s.targets) - 1 {
				emit(ctx, WASM_Instruction{kind = .Local_Tee, local_idx = idx})
			} else {
				emit(ctx, WASM_Instruction{kind = .Local_Set, local_idx = idx})
			}
		case ^parser.Subscript_Expr:
			// arr[i] = val — for multi-target, only works as last target
			extract_subscript_store(t, s.value, ctx)
		}
	}
}

extract_ann_assign :: proc(s: ^parser.Ann_Assign, ctx: ^WASM_Extract_Context) {
	#partial switch t in s.target {
	case ^parser.Name_Expr:
		wtype := python_type_to_wasm(s.annotation, ctx.type_ctx)
		if wtype == .Void { wtype = .I32 }
		idx, ok := ctx.locals_map[t.id]
		if !ok {
			idx = alloc_local(ctx, t.id, wtype)
		}
		if s.value != nil {
			extract_expr(s.value, ctx)
			val_type := infer_expr_type(s.value, ctx)
			if val_type != wtype {
				emit_conversion(ctx, val_type, wtype)
			}
			emit(ctx, WASM_Instruction{kind = .Local_Set, local_idx = idx})
		}
	}
}

extract_aug_assign :: proc(s: ^parser.Aug_Assign, ctx: ^WASM_Extract_Context) {
	#partial switch t in s.target {
	case ^parser.Name_Expr:
		idx, ok := ctx.locals_map[t.id]
		if !ok { return }
		wtype := ctx.local_types[t.id]
		emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = idx})
		extract_expr(s.value, ctx)
		emit(ctx, binop_instr(s.op, wtype))
		emit(ctx, WASM_Instruction{kind = .Local_Set, local_idx = idx})
	}
}

extract_if_stmt :: proc(s: ^parser.If_Stmt, ctx: ^WASM_Extract_Context) {
	extract_expr(s.test, ctx)
	emit(ctx, WASM_Instruction{kind = .If, block_type = .Void})
	ctx.label_depth += 1
	for stmt in s.body {
		extract_stmt(stmt, ctx)
	}
	if len(s.orelse) > 0 {
		emit(ctx, WASM_Instruction{kind = .Else})
		for stmt in s.orelse {
			extract_stmt(stmt, ctx)
		}
	}
	ctx.label_depth -= 1
	emit(ctx, WASM_Instruction{kind = .End})
}

extract_while_stmt :: proc(s: ^parser.While_Stmt, ctx: ^WASM_Extract_Context) {
	// block (break target = label 1)
	//   loop (continue target = label 0)
	//     test; i32.eqz; br_if 1
	//     body
	//     br 0
	//   end
	// end
	emit(ctx, WASM_Instruction{kind = .Block, block_type = .Void})
	emit(ctx, WASM_Instruction{kind = .Loop, block_type = .Void})
	ctx.label_depth += 2
	extract_expr(s.test, ctx)
	emit(ctx, WASM_Instruction{kind = .I32_Eqz})
	emit(ctx, WASM_Instruction{kind = .Br_If, label_idx = 1})
	for stmt in s.body {
		extract_stmt(stmt, ctx)
	}
	emit(ctx, WASM_Instruction{kind = .Br, label_idx = 0})
	ctx.label_depth -= 2
	emit(ctx, WASM_Instruction{kind = .End})
	emit(ctx, WASM_Instruction{kind = .End})
}

extract_for_stmt :: proc(s: ^parser.For_Stmt, ctx: ^WASM_Extract_Context) {
	// for i in range(n): → init counter, block/loop/br_if pattern
	// Extract loop variable name
	var_name: string
	#partial switch t in s.target {
	case ^parser.Name_Expr:
		var_name = t.id
	case:
		return // unsupported target
	}

	// Ensure loop var exists
	idx, ok := ctx.locals_map[var_name]
	if !ok {
		idx = alloc_local(ctx, var_name, .I32)
	}

	// Extract range arguments: range(stop), range(start, stop), range(start, stop, step)
	range_start: parser.Expr
	range_bound: parser.Expr
	range_step:  parser.Expr
	#partial switch iter in s.iter {
	case ^parser.Call_Expr:
		#partial switch fn in iter.func {
		case ^parser.Name_Expr:
			if fn.id == "range" {
				if len(iter.args) == 1 {
					range_bound = iter.args[0]
				} else if len(iter.args) == 2 {
					range_start = iter.args[0]
					range_bound = iter.args[1]
				} else if len(iter.args) >= 3 {
					range_start = iter.args[0]
					range_bound = iter.args[1]
					range_step  = iter.args[2]
				}
			}
		}
	}
	if range_bound == nil { return }

	// i = start (default 0)
	if range_start != nil {
		extract_expr(range_start, ctx)
		bound_type := infer_expr_type(range_start, ctx)
		if bound_type != .I32 {
			emit(ctx, WASM_Instruction{kind = .I32_Trunc_F64_S if bound_type == .F64 else .I32_Trunc_F32_S if bound_type == .F32 else .I32_Wrap_I64})
		}
	} else {
		emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 0})
	}
	emit(ctx, WASM_Instruction{kind = .Local_Set, local_idx = idx})

	// block
	//   loop
	//     local.get $i; {bound}; i32.ge_s; br_if 1
	//     {body}
	//     local.get $i; i32.const 1; i32.add; local.set $i
	//     br 0
	//   end
	// end
	emit(ctx, WASM_Instruction{kind = .Block, block_type = .Void})
	emit(ctx, WASM_Instruction{kind = .Loop, block_type = .Void})
	ctx.label_depth += 2

	emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = idx})
	extract_expr(range_bound, ctx)
	// If bound is not i32, convert
	bound_type := infer_expr_type(range_bound, ctx)
	if bound_type == .F64 {
		emit(ctx, WASM_Instruction{kind = .I32_Trunc_F64_S})
	} else if bound_type == .F32 {
		emit(ctx, WASM_Instruction{kind = .I32_Trunc_F32_S})
	} else if bound_type == .I64 {
		emit(ctx, WASM_Instruction{kind = .I32_Wrap_I64})
	}
	emit(ctx, WASM_Instruction{kind = .I32_Ge_S})
	emit(ctx, WASM_Instruction{kind = .Br_If, label_idx = 1})

	for stmt in s.body {
		extract_stmt(stmt, ctx)
	}

	// i += step (default 1)
	emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = idx})
	if range_step != nil {
		extract_expr(range_step, ctx)
		step_type := infer_expr_type(range_step, ctx)
		if step_type == .F64 {
			emit(ctx, WASM_Instruction{kind = .I32_Trunc_F64_S})
		} else if step_type == .F32 {
			emit(ctx, WASM_Instruction{kind = .I32_Trunc_F32_S})
		} else if step_type == .I64 {
			emit(ctx, WASM_Instruction{kind = .I32_Wrap_I64})
		}
	} else {
		emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 1})
	}
	emit(ctx, WASM_Instruction{kind = .I32_Add})
	emit(ctx, WASM_Instruction{kind = .Local_Set, local_idx = idx})
	emit(ctx, WASM_Instruction{kind = .Br, label_idx = 0})

	ctx.label_depth -= 2
	emit(ctx, WASM_Instruction{kind = .End})
	emit(ctx, WASM_Instruction{kind = .End})
}

extract_return_stmt :: proc(s: ^parser.Return_Stmt, ctx: ^WASM_Extract_Context) {
	if s.value != nil {
		extract_expr(s.value, ctx)
	}
	emit(ctx, WASM_Instruction{kind = .Return})
}

// === Expression extraction (post-order → stack-based) ===

extract_expr :: proc(expr: parser.Expr, ctx: ^WASM_Extract_Context) {
	if expr == nil { return }

	#partial switch e in expr {
	case ^parser.Constant_Expr:
		extract_constant(e, ctx)
	case ^parser.Name_Expr:
		extract_name(e, ctx)
	case ^parser.Bin_Op_Expr:
		extract_binop(e, ctx)
	case ^parser.Unary_Op_Expr:
		extract_unaryop(e, ctx)
	case ^parser.Compare_Expr:
		extract_compare(e, ctx)
	case ^parser.Bool_Op_Expr:
		extract_boolop(e, ctx)
	case ^parser.If_Expr:
		extract_if_expr(e, ctx)
	case ^parser.Call_Expr:
		extract_call(e, ctx)
	case ^parser.Subscript_Expr:
		extract_subscript(e, ctx)
	}
}

extract_constant :: proc(e: ^parser.Constant_Expr, ctx: ^WASM_Extract_Context) {
	#partial switch v in e.value {
	case i64:
		if v > i64(max(i32)) || v < i64(min(i32)) {
			// Value exceeds i32 range — use i64
			emit(ctx, WASM_Instruction{kind = .I64_Const, i64_val = v})
		} else {
			emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = i32(v)})
		}
	case f64:
		emit(ctx, WASM_Instruction{kind = .F64_Const, f64_val = f64(v)})
	case bool:
		emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 1 if v else 0})
	}
}

extract_name :: proc(e: ^parser.Name_Expr, ctx: ^WASM_Extract_Context) {
	if e.id == "True" {
		emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 1})
		return
	}
	if e.id == "False" {
		emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 0})
		return
	}
	idx, ok := ctx.locals_map[e.id]
	if ok {
		emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = idx})
		return
	}
	// Check globals
	if gidx, gok := ctx.global_map[e.id]; gok {
		emit(ctx, WASM_Instruction{kind = .Global_Get, local_idx = gidx})
		return
	}
	// Unknown name — emit 0 as fallback
	emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 0})
}

extract_binop :: proc(e: ^parser.Bin_Op_Expr, ctx: ^WASM_Extract_Context) {
	ltype := infer_expr_type(e.left, ctx)
	rtype := infer_expr_type(e.right, ctx)

	// True division: promote to f64
	if e.op == .Div {
		extract_expr(e.left, ctx)
		if ltype == .I32 {
			emit(ctx, WASM_Instruction{kind = .F64_Convert_I32_S})
		} else if ltype == .F32 {
			emit(ctx, WASM_Instruction{kind = .F64_Promote_F32})
		}
		extract_expr(e.right, ctx)
		if rtype == .I32 {
			emit(ctx, WASM_Instruction{kind = .F64_Convert_I32_S})
		} else if rtype == .F32 {
			emit(ctx, WASM_Instruction{kind = .F64_Promote_F32})
		}
		emit(ctx, WASM_Instruction{kind = .F64_Div})
		return
	}

	// Determine result type
	result_type := promote_types(ltype, rtype)

	// Float floor_div: floor(a / b)
	if e.op == .Floor_Div && (result_type == .F32 || result_type == .F64) {
		extract_expr(e.left, ctx)
		if ltype != result_type { emit_conversion(ctx, ltype, result_type) }
		extract_expr(e.right, ctx)
		if rtype != result_type { emit_conversion(ctx, rtype, result_type) }
		emit(ctx, WASM_Instruction{kind = .F64_Div if result_type == .F64 else .F32_Div})
		emit(ctx, WASM_Instruction{kind = .F64_Floor if result_type == .F64 else .F32_Floor})
		return
	}

	// Float mod: a - floor(a/b) * b
	if e.op == .Mod && (result_type == .F32 || result_type == .F64) {
		a_temp := get_or_alloc_temp_named(ctx, "__mod_a", result_type)
		b_temp := get_or_alloc_temp_named(ctx, "__mod_b", result_type)
		fv_temp := get_or_alloc_temp_named(ctx, "__mod_fv", result_type)
		is_f64 := result_type == .F64
		// Compute a and b, save to temps
		extract_expr(e.left, ctx)
		if ltype != result_type { emit_conversion(ctx, ltype, result_type) }
		emit(ctx, WASM_Instruction{kind = .Local_Tee, local_idx = a_temp})
		extract_expr(e.right, ctx)
		if rtype != result_type { emit_conversion(ctx, rtype, result_type) }
		emit(ctx, WASM_Instruction{kind = .Local_Tee, local_idx = b_temp})
		// stack: [a, b] → div → [a/b] → floor → [floor(a/b)]
		emit(ctx, WASM_Instruction{kind = .F64_Div if is_f64 else .F32_Div})
		emit(ctx, WASM_Instruction{kind = .F64_Floor if is_f64 else .F32_Floor})
		// [floor(a/b)] * b → [floor(a/b)*b]
		emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = b_temp})
		emit(ctx, WASM_Instruction{kind = .F64_Mul if is_f64 else .F32_Mul})
		emit(ctx, WASM_Instruction{kind = .Local_Set, local_idx = fv_temp})
		// a - floor(a/b)*b: push a first (bottom), then fv (top), sub = bottom - top
		emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = a_temp})
		emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = fv_temp})
		emit(ctx, WASM_Instruction{kind = .F64_Sub if is_f64 else .F32_Sub})
		return
	}

	extract_expr(e.left, ctx)
	if ltype != result_type {
		emit_conversion(ctx, ltype, result_type)
	}
	extract_expr(e.right, ctx)
	if rtype != result_type {
		emit_conversion(ctx, rtype, result_type)
	}
	emit(ctx, binop_instr(e.op, result_type))
}

extract_unaryop :: proc(e: ^parser.Unary_Op_Expr, ctx: ^WASM_Extract_Context) {
	optype := infer_expr_type(e.operand, ctx)

	switch e.op {
	case .USub:
		if optype == .I32 {
			emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 0})
			extract_expr(e.operand, ctx)
			emit(ctx, WASM_Instruction{kind = .I32_Sub})
		} else if optype == .F32 {
			extract_expr(e.operand, ctx)
			emit(ctx, WASM_Instruction{kind = .F32_Neg})
		} else {
			extract_expr(e.operand, ctx)
			emit(ctx, WASM_Instruction{kind = .F64_Neg})
		}
	case .Not:
		extract_expr(e.operand, ctx)
		emit(ctx, WASM_Instruction{kind = .I32_Eqz})
	case .Invert:
		// Bitwise NOT: xor with -1 (i32 only — i64 bitwise ops not in WASM instruction set)
		extract_expr(e.operand, ctx)
		op_type := infer_expr_type(e.operand, ctx)
		if op_type == .I64 {
			emit(ctx, WASM_Instruction{kind = .I32_Wrap_I64})
		}
		emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = -1})
		emit(ctx, WASM_Instruction{kind = .I32_Xor})
	case .UAdd:
		extract_expr(e.operand, ctx)
	}
}

extract_compare :: proc(e: ^parser.Compare_Expr, ctx: ^WASM_Extract_Context) {
	if len(e.ops) < 1 || len(e.comparators) < 1 { return }

	ltype := infer_expr_type(e.left, ctx)
	rtype := infer_expr_type(e.comparators[0], ctx)
	cmp_type := promote_types(ltype, rtype)

	extract_expr(e.left, ctx)
	if ltype != cmp_type {
		emit_conversion(ctx, ltype, cmp_type)
	}
	extract_expr(e.comparators[0], ctx)
	if rtype != cmp_type {
		emit_conversion(ctx, rtype, cmp_type)
	}

	emit(ctx, cmp_instr(e.ops[0], cmp_type))
}

extract_boolop :: proc(e: ^parser.Bool_Op_Expr, ctx: ^WASM_Extract_Context) {
	if len(e.values) < 2 { return }

	// a and b → a; if a then b else 0
	// a or b  → a; if a then a else b
	extract_expr(e.values[0], ctx)
	for i := 1; i < len(e.values); i += 1 {
		if e.op == .And {
			emit(ctx, WASM_Instruction{kind = .If, block_type = .I32})
			extract_expr(e.values[i], ctx)
			emit(ctx, WASM_Instruction{kind = .Else})
			emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 0})
			emit(ctx, WASM_Instruction{kind = .End})
		} else {
			// or: duplicate test, if truthy keep it, else eval next
			// Use unique temp per or-level to avoid clobbering in chained or
			temp_name := fmt.tprintf("__or_tmp_%d", ctx.or_temp_counter)
			ctx.or_temp_counter += 1
			temp_idx := get_or_alloc_temp_named(ctx, temp_name, .I32)
			emit(ctx, WASM_Instruction{kind = .Local_Tee, local_idx = temp_idx})
			emit(ctx, WASM_Instruction{kind = .If, block_type = .I32})
			emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = temp_idx})
			emit(ctx, WASM_Instruction{kind = .Else})
			extract_expr(e.values[i], ctx)
			emit(ctx, WASM_Instruction{kind = .End})
		}
	}
}

extract_if_expr :: proc(e: ^parser.If_Expr, ctx: ^WASM_Extract_Context) {
	result_type := infer_expr_type(e.body, ctx)
	extract_expr(e.test, ctx)
	emit(ctx, WASM_Instruction{kind = .If, block_type = result_type})
	extract_expr(e.body, ctx)
	emit(ctx, WASM_Instruction{kind = .Else})
	extract_expr(e.orelse, ctx)
	emit(ctx, WASM_Instruction{kind = .End})
}

extract_call :: proc(e: ^parser.Call_Expr, ctx: ^WASM_Extract_Context) {
	#partial switch f in e.func {
	case ^parser.Name_Expr:
		// Built-in math functions
		if f.id == "abs" && len(e.args) == 1 {
			arg_type := infer_expr_type(e.args[0], ctx)
			extract_expr(e.args[0], ctx)
			if arg_type == .F32 {
				emit(ctx, WASM_Instruction{kind = .F32_Abs})
			} else if arg_type == .F64 {
				emit(ctx, WASM_Instruction{kind = .F64_Abs})
			} else {
				// i32 abs: if x<0 then -x else x
				temp := get_or_alloc_temp(ctx, .I32)
				emit(ctx, WASM_Instruction{kind = .Local_Tee, local_idx = temp})
				emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 0})
				emit(ctx, WASM_Instruction{kind = .I32_Lt_S})
				emit(ctx, WASM_Instruction{kind = .If, block_type = .I32})
				emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 0})
				emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = temp})
				emit(ctx, WASM_Instruction{kind = .I32_Sub})
				emit(ctx, WASM_Instruction{kind = .Else})
				emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = temp})
				emit(ctx, WASM_Instruction{kind = .End})
			}
			return
		}
		if f.id == "min" && len(e.args) == 2 {
			arg_type := infer_expr_type(e.args[0], ctx)
			extract_expr(e.args[0], ctx)
			extract_expr(e.args[1], ctx)
			if arg_type == .F32 {
				emit(ctx, WASM_Instruction{kind = .F32_Min})
			} else if arg_type == .F64 {
				emit(ctx, WASM_Instruction{kind = .F64_Min})
			} else {
				// i32 min via select: a < b ? a : b
				// Stack: [a, b] → need to compare then select
				temp_a := get_or_alloc_temp(ctx, .I32)
				temp_b := get_or_alloc_temp_named(ctx, "__min_b", .I32)
				emit(ctx, WASM_Instruction{kind = .Local_Set, local_idx = temp_b})
				emit(ctx, WASM_Instruction{kind = .Local_Set, local_idx = temp_a})
				emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = temp_a})
				emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = temp_b})
				emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = temp_a})
				emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = temp_b})
				emit(ctx, WASM_Instruction{kind = .I32_Lt_S})
				emit(ctx, WASM_Instruction{kind = .Select})
			}
			return
		}
		if f.id == "max" && len(e.args) == 2 {
			arg_type := infer_expr_type(e.args[0], ctx)
			extract_expr(e.args[0], ctx)
			extract_expr(e.args[1], ctx)
			if arg_type == .F32 {
				emit(ctx, WASM_Instruction{kind = .F32_Max})
			} else if arg_type == .F64 {
				emit(ctx, WASM_Instruction{kind = .F64_Max})
			} else {
				temp_a := get_or_alloc_temp(ctx, .I32)
				temp_b := get_or_alloc_temp_named(ctx, "__max_b", .I32)
				emit(ctx, WASM_Instruction{kind = .Local_Set, local_idx = temp_b})
				emit(ctx, WASM_Instruction{kind = .Local_Set, local_idx = temp_a})
				emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = temp_a})
				emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = temp_b})
				emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = temp_a})
				emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = temp_b})
				emit(ctx, WASM_Instruction{kind = .I32_Gt_S})
				emit(ctx, WASM_Instruction{kind = .Select})
			}
			return
		}
		if f.id == "len" && len(e.args) == 1 {
			// len(x) → local.get $x_len
			#partial switch arg in e.args[0] {
			case ^parser.Name_Expr:
				len_name := fmt.tprintf("%s_len", arg.id)
				if idx, ok := ctx.locals_map[len_name]; ok {
					emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = idx})
					return
				}
			}
			emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 0})
			return
		}
		// range() is handled in for_stmt extraction — if we get here, it's a standalone call
		if f.id == "range" { return }

		// print() → host import call
		if f.id == "print" && len(e.args) >= 1 {
			extract_print_call(e, ctx)
			return
		}

		// @wasm function call
		if func_idx, ok := ctx.func_map[f.id]; ok {
			for arg in e.args {
				extract_expr(arg, ctx)
			}
			emit(ctx, WASM_Instruction{kind = .Call, func_idx = func_idx})
			return
		}

		// Unknown call — push 0 as fallback
		emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 0})

	case ^parser.Attribute_Expr:
		// math.sin(x), math.cos(x), etc.
		#partial switch v in f.value {
		case ^parser.Name_Expr:
			if v.id == "math" {
				extract_math_call(f.attr, e, ctx)
				return
			}
		}
		// Unknown attribute call — push 0
		emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 0})
	}
}

// Emit a print() call via host import.
extract_print_call :: proc(e: ^parser.Call_Expr, ctx: ^WASM_Extract_Context) {
	if ctx.wasi {
		// WASI fd_write: need to write value to memory, then call fd_write
		// Simplified: write i32 value as decimal to memory, call fd_write
		extract_wasi_print(e, ctx)
		return
	}
	// Browser mode: call console_log_i32 or console_log_f64
	arg_type := infer_expr_type(e.args[0], ctx)
	extract_expr(e.args[0], ctx)
	if arg_type == .F64 || arg_type == .F32 {
		if arg_type == .F32 {
			emit(ctx, WASM_Instruction{kind = .F64_Promote_F32})
		}
		if idx, ok := ctx.import_map["console_log_f64"]; ok {
			emit(ctx, WASM_Instruction{kind = .Call, func_idx = idx})
		}
	} else {
		if idx, ok := ctx.import_map["console_log_i32"]; ok {
			emit(ctx, WASM_Instruction{kind = .Call, func_idx = idx})
		}
	}
}

// Emit WASI print: convert value to string in memory, fd_write to stdout.
extract_wasi_print :: proc(e: ^parser.Call_Expr, ctx: ^WASM_Extract_Context) {
	// Reserve memory at offset 0 for iov_buf (8 bytes: ptr, len)
	// and at offset 8+ for the actual string data
	// Simple approach: write decimal digits at offset 16, iov at offset 0
	fd_write_idx, ok := ctx.import_map["fd_write"]
	if !ok { return }

	arg_type := infer_expr_type(e.args[0], ctx)
	extract_expr(e.args[0], ctx)

	// Convert to i32 if needed
	if arg_type == .F64 {
		emit(ctx, WASM_Instruction{kind = .I32_Trunc_F64_S})
	} else if arg_type == .F32 {
		emit(ctx, WASM_Instruction{kind = .I32_Trunc_F32_S})
	} else if arg_type == .I64 {
		emit(ctx, WASM_Instruction{kind = .I32_Wrap_I64})
	}

	// Store value at offset 16 as a single ASCII digit (simplified)
	// For a proper implementation, we'd need itoa in WASM instructions
	// Simplified: store single byte '0'+val for 0-9, or '?' for larger
	buf_temp := get_or_alloc_temp_named(ctx, "__print_val", .I32)
	emit(ctx, WASM_Instruction{kind = .Local_Set, local_idx = buf_temp})

	// Store the digit at offset 16
	emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 16})  // address
	emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = buf_temp})
	emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 48}) // '0'
	emit(ctx, WASM_Instruction{kind = .I32_Add})
	emit(ctx, WASM_Instruction{kind = .I32_Store8, mem_align = 0, mem_offset = 0})

	// Store newline at offset 17
	emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 17})
	emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 10}) // '\n'
	emit(ctx, WASM_Instruction{kind = .I32_Store8, mem_align = 0, mem_offset = 0})

	// Set iov_buf: ptr=16, len=2 at offset 0
	emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 0})
	emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 16})
	emit(ctx, WASM_Instruction{kind = .I32_Store, mem_align = 0, mem_offset = 0})
	emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 4})
	emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 2})
	emit(ctx, WASM_Instruction{kind = .I32_Store, mem_align = 0, mem_offset = 0})

	// fd_write(1, 0, 1, 8) → stdout, iov at 0, 1 iov, nwritten at 8
	emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 1})   // fd = stdout
	emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 0})   // iovs ptr
	emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 1})   // iovs_len
	emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 8})   // nwritten ptr
	emit(ctx, WASM_Instruction{kind = .Call, func_idx = fd_write_idx})
	emit(ctx, WASM_Instruction{kind = .Drop}) // discard fd_write return value
}

// Emit math.X() call via host import or native instruction.
extract_math_call :: proc(attr: string, e: ^parser.Call_Expr, ctx: ^WASM_Extract_Context) {
	// Native WASM instructions for some math functions
	switch attr {
	case "floor":
		if len(e.args) >= 1 {
			extract_expr(e.args[0], ctx)
			arg_type := infer_expr_type(e.args[0], ctx)
			if arg_type == .I32 { emit(ctx, WASM_Instruction{kind = .F64_Convert_I32_S}) }
			if arg_type == .F32 { emit(ctx, WASM_Instruction{kind = .F64_Promote_F32}) }
			emit(ctx, WASM_Instruction{kind = .F64_Floor})
		}
		return
	case "ceil":
		if len(e.args) >= 1 {
			extract_expr(e.args[0], ctx)
			arg_type := infer_expr_type(e.args[0], ctx)
			if arg_type == .I32 { emit(ctx, WASM_Instruction{kind = .F64_Convert_I32_S}) }
			if arg_type == .F32 { emit(ctx, WASM_Instruction{kind = .F64_Promote_F32}) }
			emit(ctx, WASM_Instruction{kind = .F64_Ceil})
		}
		return
	case "sqrt":
		if len(e.args) >= 1 {
			extract_expr(e.args[0], ctx)
			arg_type := infer_expr_type(e.args[0], ctx)
			if arg_type == .I32 { emit(ctx, WASM_Instruction{kind = .F64_Convert_I32_S}) }
			if arg_type == .F32 { emit(ctx, WASM_Instruction{kind = .F64_Promote_F32}) }
			emit(ctx, WASM_Instruction{kind = .F64_Sqrt})
		}
		return
	case "trunc":
		if len(e.args) >= 1 {
			extract_expr(e.args[0], ctx)
			arg_type := infer_expr_type(e.args[0], ctx)
			if arg_type == .I32 { emit(ctx, WASM_Instruction{kind = .F64_Convert_I32_S}) }
			if arg_type == .F32 { emit(ctx, WASM_Instruction{kind = .F64_Promote_F32}) }
			emit(ctx, WASM_Instruction{kind = .F64_Trunc})
		}
		return
	case "fabs":
		if len(e.args) >= 1 {
			extract_expr(e.args[0], ctx)
			arg_type := infer_expr_type(e.args[0], ctx)
			if arg_type == .I32 { emit(ctx, WASM_Instruction{kind = .F64_Convert_I32_S}) }
			if arg_type == .F32 { emit(ctx, WASM_Instruction{kind = .F64_Promote_F32}) }
			emit(ctx, WASM_Instruction{kind = .F64_Abs})
		}
		return
	}

	// Host imports for transcendental functions
	import_name := fmt.tprintf("math_%s", attr)
	idx, ok := ctx.import_map[import_name]
	if !ok { return }

	// Push args, promoting to f64
	for arg in e.args {
		extract_expr(arg, ctx)
		arg_type := infer_expr_type(arg, ctx)
		if arg_type == .I32 { emit(ctx, WASM_Instruction{kind = .F64_Convert_I32_S}) }
		if arg_type == .F32 { emit(ctx, WASM_Instruction{kind = .F64_Promote_F32}) }
	}
	emit(ctx, WASM_Instruction{kind = .Call, func_idx = idx})
}

extract_subscript :: proc(e: ^parser.Subscript_Expr, ctx: ^WASM_Extract_Context) {
	// arr[i] → memory load
	#partial switch v in e.value {
	case ^parser.Name_Expr:
		ann, ann_ok := ctx.param_annotations[v.id]
		if ann_ok && is_memory_type(ann) {
			// Memory type: base_ptr + i * elem_size
			ptr_name := fmt.tprintf("%s_ptr", v.id)
			ptr_idx, ptr_ok := ctx.locals_map[ptr_name]
			if !ptr_ok {
				ptr_idx = ctx.locals_map[v.id]
			}
			emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = ptr_idx})
			extract_expr(e.slice, ctx)
			elem_size := memory_element_size(ann, ctx.type_ctx)
			if elem_size > 1 {
				emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = i32(elem_size)})
				emit(ctx, WASM_Instruction{kind = .I32_Mul})
			}
			emit(ctx, WASM_Instruction{kind = .I32_Add})
			load_kind := memory_load_kind(ann, ctx.type_ctx)
			emit(ctx, WASM_Instruction{kind = load_kind, mem_align = 0, mem_offset = 0})
			return
		}
	}
	// Fallback
	emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = 0})
}

extract_subscript_store :: proc(sub: ^parser.Subscript_Expr, value: parser.Expr, ctx: ^WASM_Extract_Context) {
	#partial switch v in sub.value {
	case ^parser.Name_Expr:
		ann, ann_ok := ctx.param_annotations[v.id]
		if ann_ok && is_memory_type(ann) {
			ptr_name := fmt.tprintf("%s_ptr", v.id)
			ptr_idx, ptr_ok := ctx.locals_map[ptr_name]
			if !ptr_ok {
				ptr_idx = ctx.locals_map[v.id]
			}
			// addr = base_ptr + i * elem_size
			emit(ctx, WASM_Instruction{kind = .Local_Get, local_idx = ptr_idx})
			extract_expr(sub.slice, ctx)
			elem_size := memory_element_size(ann, ctx.type_ctx)
			if elem_size > 1 {
				emit(ctx, WASM_Instruction{kind = .I32_Const, i32_val = i32(elem_size)})
				emit(ctx, WASM_Instruction{kind = .I32_Mul})
			}
			emit(ctx, WASM_Instruction{kind = .I32_Add})
			// value
			extract_expr(value, ctx)
			// store
			elem_type := memory_elem_wasm_type(ann, ctx.type_ctx)
			store_kind: WASM_Instr_Kind
			switch elem_type {
			case .I32: store_kind = .I32_Store
			case .I64: store_kind = .I64_Store
			case .F32: store_kind = .F32_Store
			case .F64: store_kind = .F64_Store
			case .Void: store_kind = .I32_Store8
			}
			// bytes → store8
			#partial switch ne in sub.value {
			case ^parser.Name_Expr:
				#partial switch a in ann {
				case ^parser.Name_Expr:
					if a.id == "bytes" { store_kind = .I32_Store8 }
				}
			}
			emit(ctx, WASM_Instruction{kind = store_kind, mem_align = 0, mem_offset = 0})
		}
	}
}

// === Helpers ===

// Get or allocate a temp local for internal use.
get_or_alloc_temp :: proc(ctx: ^WASM_Extract_Context, type: WASM_Value_Type) -> int {
	return get_or_alloc_temp_named(ctx, "__temp", type)
}

get_or_alloc_temp_named :: proc(ctx: ^WASM_Extract_Context, name: string, type: WASM_Value_Type) -> int {
	if idx, ok := ctx.locals_map[name]; ok {
		return idx
	}
	return alloc_local(ctx, name, type)
}

// Infer the WASM type of an expression.
infer_expr_type :: proc(expr: parser.Expr, ctx: ^WASM_Extract_Context) -> WASM_Value_Type {
	if expr == nil { return .I32 }

	#partial switch e in expr {
	case ^parser.Constant_Expr:
		#partial switch v in e.value {
		case i64:
			if v > 2147483647 || v < -2147483648 { return .I64 }
			return .I32
		case f64:  return .F64
		case bool: return .I32
		}
	case ^parser.Name_Expr:
		if e.id == "True" || e.id == "False" { return .I32 }
		if wtype, ok := ctx.local_types[e.id]; ok {
			return wtype
		}
		if gtype, gok := ctx.global_types[e.id]; gok {
			return gtype
		}
	case ^parser.Bin_Op_Expr:
		if e.op == .Div { return .F64 }
		ltype := infer_expr_type(e.left, ctx)
		rtype := infer_expr_type(e.right, ctx)
		return promote_types(ltype, rtype)
	case ^parser.Unary_Op_Expr:
		if e.op == .Not { return .I32 }
		return infer_expr_type(e.operand, ctx)
	case ^parser.Compare_Expr:
		return .I32
	case ^parser.Bool_Op_Expr:
		return .I32
	case ^parser.If_Expr:
		return infer_expr_type(e.body, ctx)
	case ^parser.Call_Expr:
		#partial switch f in e.func {
		case ^parser.Name_Expr:
			if f.id == "abs" && len(e.args) >= 1 { return infer_expr_type(e.args[0], ctx) }
			if f.id == "min" && len(e.args) >= 1 { return infer_expr_type(e.args[0], ctx) }
			if f.id == "max" && len(e.args) >= 1 { return infer_expr_type(e.args[0], ctx) }
			if f.id == "len" { return .I32 }
			if f.id == "print" { return .Void }
		case ^parser.Attribute_Expr:
			#partial switch v in f.value {
			case ^parser.Name_Expr:
				if v.id == "math" { return .F64 } // math functions return f64
			}
		}
	case ^parser.Subscript_Expr:
		#partial switch v in e.value {
		case ^parser.Name_Expr:
			if ann, ok := ctx.param_annotations[v.id]; ok {
				if is_memory_type(ann) {
					return memory_elem_wasm_type(ann, ctx.type_ctx)
				}
			}
		}
	}
	return .I32
}

// Type promotion: I32+F64 → F64, F32+F64 → F64, etc.
promote_types :: proc(a, b: WASM_Value_Type) -> WASM_Value_Type {
	if a == b { return a }
	if a == .F64 || b == .F64 { return .F64 }
	if a == .F32 || b == .F32 { return .F32 }
	if a == .I64 || b == .I64 { return .I64 }
	return .I32
}

// Emit type conversion instruction.
emit_conversion :: proc(ctx: ^WASM_Extract_Context, from: WASM_Value_Type, to: WASM_Value_Type) {
	if from == to { return }
	switch {
	case from == .I32 && to == .F64:
		emit(ctx, WASM_Instruction{kind = .F64_Convert_I32_S})
	case from == .I32 && to == .F32:
		emit(ctx, WASM_Instruction{kind = .F32_Convert_I32_S})
	case from == .I32 && to == .I64:
		emit(ctx, WASM_Instruction{kind = .I64_Extend_I32_S})
	case from == .F32 && to == .F64:
		emit(ctx, WASM_Instruction{kind = .F64_Promote_F32})
	case from == .F64 && to == .F32:
		emit(ctx, WASM_Instruction{kind = .F32_Demote_F64})
	case from == .F64 && to == .I32:
		emit(ctx, WASM_Instruction{kind = .I32_Trunc_F64_S})
	case from == .F32 && to == .I32:
		emit(ctx, WASM_Instruction{kind = .I32_Trunc_F32_S})
	case from == .I64 && to == .I32:
		emit(ctx, WASM_Instruction{kind = .I32_Wrap_I64})
	}
}

// Map Python binary op + WASM type to instruction.
binop_instr :: proc(op: parser.Binary_Op, type: WASM_Value_Type) -> WASM_Instruction {
	switch type {
	case .I32:
		#partial switch op {
		case .Add:       return WASM_Instruction{kind = .I32_Add}
		case .Sub:       return WASM_Instruction{kind = .I32_Sub}
		case .Mult:      return WASM_Instruction{kind = .I32_Mul}
		case .Floor_Div: return WASM_Instruction{kind = .I32_Div_S}
		case .Mod:       return WASM_Instruction{kind = .I32_Rem_S}
		case .Bit_And:   return WASM_Instruction{kind = .I32_And}
		case .Bit_Or:    return WASM_Instruction{kind = .I32_Or}
		case .Bit_Xor:   return WASM_Instruction{kind = .I32_Xor}
		case .LShift:    return WASM_Instruction{kind = .I32_Shl}
		case .RShift:    return WASM_Instruction{kind = .I32_Shr_S}
		case .Pow:
			fmt.eprintfln("warning: WASM has no integer power instruction — using multiply as approximation")
			return WASM_Instruction{kind = .I32_Mul}
		case .Div:       return WASM_Instruction{kind = .I32_Div_S}
		case .Mat_Mult:  return WASM_Instruction{kind = .I32_Mul}
		}
	case .I64:
		#partial switch op {
		case .Add:       return WASM_Instruction{kind = .I64_Add}
		case .Sub:       return WASM_Instruction{kind = .I64_Sub}
		case .Mult:      return WASM_Instruction{kind = .I64_Mul}
		case .Floor_Div: return WASM_Instruction{kind = .I64_Div_S}
		case .Mod:       return WASM_Instruction{kind = .I64_Rem_S}
		}
	case .F32:
		#partial switch op {
		case .Add:  return WASM_Instruction{kind = .F32_Add}
		case .Sub:  return WASM_Instruction{kind = .F32_Sub}
		case .Mult: return WASM_Instruction{kind = .F32_Mul}
		case .Div:  return WASM_Instruction{kind = .F32_Div}
		}
	case .F64:
		#partial switch op {
		case .Add:  return WASM_Instruction{kind = .F64_Add}
		case .Sub:  return WASM_Instruction{kind = .F64_Sub}
		case .Mult: return WASM_Instruction{kind = .F64_Mul}
		case .Div:  return WASM_Instruction{kind = .F64_Div}
		}
	case .Void:
		return WASM_Instruction{kind = .Nop}
	}
	return WASM_Instruction{kind = .Nop}
}

// Map comparison op + type to instruction.
cmp_instr :: proc(op: parser.Cmp_Op, type: WASM_Value_Type) -> WASM_Instruction {
	switch type {
	case .I32:
		#partial switch op {
		case .Eq:     return WASM_Instruction{kind = .I32_Eq}
		case .Not_Eq: return WASM_Instruction{kind = .I32_Ne}
		case .Lt:     return WASM_Instruction{kind = .I32_Lt_S}
		case .Gt:     return WASM_Instruction{kind = .I32_Gt_S}
		case .Lt_E:   return WASM_Instruction{kind = .I32_Le_S}
		case .Gt_E:   return WASM_Instruction{kind = .I32_Ge_S}
		}
	case .F32:
		#partial switch op {
		case .Eq:     return WASM_Instruction{kind = .F32_Eq}
		case .Not_Eq: return WASM_Instruction{kind = .F32_Ne}
		case .Lt:     return WASM_Instruction{kind = .F32_Lt}
		case .Gt:     return WASM_Instruction{kind = .F32_Gt}
		case .Lt_E:   return WASM_Instruction{kind = .F32_Le}
		case .Gt_E:   return WASM_Instruction{kind = .F32_Ge}
		}
	case .F64:
		#partial switch op {
		case .Eq:     return WASM_Instruction{kind = .F64_Eq}
		case .Not_Eq: return WASM_Instruction{kind = .F64_Ne}
		case .Lt:     return WASM_Instruction{kind = .F64_Lt}
		case .Gt:     return WASM_Instruction{kind = .F64_Gt}
		case .Lt_E:   return WASM_Instruction{kind = .F64_Le}
		case .Gt_E:   return WASM_Instruction{kind = .F64_Ge}
		}
	case .I64:
		#partial switch op {
		case .Eq:     return WASM_Instruction{kind = .I64_Eq}
		case .Not_Eq: return WASM_Instruction{kind = .I64_Ne}
		case .Lt:     return WASM_Instruction{kind = .I64_Lt_S}
		case .Gt:     return WASM_Instruction{kind = .I64_Gt_S}
		case .Lt_E:   return WASM_Instruction{kind = .I64_Le_S}
		case .Gt_E:   return WASM_Instruction{kind = .I64_Ge_S}
		}
	case .Void:
		return WASM_Instruction{kind = .I32_Eq}
	}
	return WASM_Instruction{kind = .I32_Eq}
}
