package parser

import "core:encoding/base64"
import "core:encoding/json"
import "core:mem"
import "core:strings"

// ==================== Entry Point ====================

json_to_module :: proc(data: []byte, alloc: mem.Allocator) -> (^Module, Parse_Error) {
	val, err := json.parse(data, .JSON, true)
	if err != .None {
		return nil, Bridge_Error{"JSON parse error"}
	}
	defer json.destroy_value(val)

	obj, is_obj := val.(json.Object)
	if !is_obj {
		return nil, Bridge_Error{"expected Module object at root"}
	}

	mod := new(Module, alloc)
	mod.loc = get_loc(obj)
	mod.body = conv_stmts(obj["body"], alloc)
	mod.type_ignores = conv_type_ignores(obj["type_ignores"], alloc)
	return mod, nil
}

// ==================== Helpers ====================

get_str :: proc(obj: json.Object, key: string) -> string {
	val, ok := obj[key]
	if !ok do return ""
	s, is_str := val.(json.String)
	if !is_str do return ""
	return s
}

get_int :: proc(obj: json.Object, key: string) -> i64 {
	val, ok := obj[key]
	if !ok do return 0
	i, is_int := val.(json.Integer)
	if !is_int do return 0
	return i
}

get_loc :: proc(obj: json.Object) -> Src_Loc {
	v, ok := obj["_loc"]
	if !ok do return {}
	arr, is_arr := v.(json.Array)
	if !is_arr || len(arr) < 4 do return {}
	loc: Src_Loc
	if i, iok := arr[0].(json.Integer); iok do loc.line = i32(i)
	if i, iok := arr[1].(json.Integer); iok do loc.col = i32(i)
	if i, iok := arr[2].(json.Integer); iok do loc.end_line = i32(i)
	if i, iok := arr[3].(json.Integer); iok do loc.end_col = i32(i)
	return loc
}

to_f64 :: proc(v: json.Value) -> f64 {
	#partial switch val in v {
	case json.Float:
		return f64(val)
	case json.Integer:
		return f64(val)
	}
	return 0
}

clone_str :: proc(s: string, alloc: mem.Allocator) -> string {
	if len(s) == 0 do return ""
	return strings.clone(s, alloc)
}

// ==================== Array Converters ====================

conv_stmts :: proc(v: json.Value, alloc: mem.Allocator) -> []Stmt {
	arr, is_arr := v.(json.Array)
	if !is_arr do return nil
	result := make([]Stmt, len(arr), alloc)
	for item, i in arr {
		result[i] = conv_stmt(item, alloc)
	}
	return result
}

conv_exprs :: proc(v: json.Value, alloc: mem.Allocator) -> []Expr {
	arr, is_arr := v.(json.Array)
	if !is_arr do return nil
	result := make([]Expr, len(arr), alloc)
	for item, i in arr {
		result[i] = conv_expr(item, alloc)
	}
	return result
}

conv_patterns :: proc(v: json.Value, alloc: mem.Allocator) -> []Pattern {
	arr, is_arr := v.(json.Array)
	if !is_arr do return nil
	result := make([]Pattern, len(arr), alloc)
	for item, i in arr {
		result[i] = conv_pattern(item, alloc)
	}
	return result
}

conv_type_params :: proc(v: json.Value, alloc: mem.Allocator) -> []Type_Param {
	arr, is_arr := v.(json.Array)
	if !is_arr do return nil
	result := make([]Type_Param, len(arr), alloc)
	for item, i in arr {
		result[i] = conv_type_param(item, alloc)
	}
	return result
}

conv_strings :: proc(v: json.Value, alloc: mem.Allocator) -> []string {
	arr, is_arr := v.(json.Array)
	if !is_arr do return nil
	result := make([]string, len(arr), alloc)
	for item, i in arr {
		if s, ok := item.(json.String); ok {
			result[i] = clone_str(s, alloc)
		}
	}
	return result
}

// ==================== Op Converters ====================

conv_binary_op :: proc(v: json.Value) -> Binary_Op {
	obj, is_obj := v.(json.Object)
	if !is_obj do return .Add
	t := get_str(obj, "_t")
	switch t {
	case "Add":      return .Add
	case "Sub":      return .Sub
	case "Mult":     return .Mult
	case "MatMult":  return .Mat_Mult
	case "Div":      return .Div
	case "Mod":      return .Mod
	case "Pow":      return .Pow
	case "LShift":   return .LShift
	case "RShift":   return .RShift
	case "BitOr":    return .Bit_Or
	case "BitXor":   return .Bit_Xor
	case "BitAnd":   return .Bit_And
	case "FloorDiv": return .Floor_Div
	}
	return .Add
}

conv_unary_op :: proc(v: json.Value) -> Unary_Op {
	obj, is_obj := v.(json.Object)
	if !is_obj do return .Not
	t := get_str(obj, "_t")
	switch t {
	case "Invert": return .Invert
	case "Not":    return .Not
	case "UAdd":   return .UAdd
	case "USub":   return .USub
	}
	return .Not
}

conv_bool_op :: proc(v: json.Value) -> Bool_Op_Kind {
	obj, is_obj := v.(json.Object)
	if !is_obj do return .And
	t := get_str(obj, "_t")
	switch t {
	case "And": return .And
	case "Or":  return .Or
	}
	return .And
}

conv_cmp_op :: proc(v: json.Value) -> Cmp_Op {
	obj, is_obj := v.(json.Object)
	if !is_obj do return .Eq
	t := get_str(obj, "_t")
	switch t {
	case "Eq":    return .Eq
	case "NotEq": return .Not_Eq
	case "Lt":    return .Lt
	case "LtE":   return .Lt_E
	case "Gt":    return .Gt
	case "GtE":   return .Gt_E
	case "Is":    return .Is
	case "IsNot": return .Is_Not
	case "In":    return .In
	case "NotIn": return .Not_In
	}
	return .Eq
}

conv_cmp_ops :: proc(v: json.Value, alloc: mem.Allocator) -> []Cmp_Op {
	arr, is_arr := v.(json.Array)
	if !is_arr do return nil
	result := make([]Cmp_Op, len(arr), alloc)
	for item, i in arr {
		result[i] = conv_cmp_op(item)
	}
	return result
}

conv_expr_context :: proc(v: json.Value) -> Expr_Context {
	obj, is_obj := v.(json.Object)
	if !is_obj do return .Load
	t := get_str(obj, "_t")
	switch t {
	case "Load":  return .Load
	case "Store": return .Store
	case "Del":   return .Del
	}
	return .Load
}

// ==================== Statement Converter ====================

conv_stmt :: proc(v: json.Value, alloc: mem.Allocator) -> Stmt {
	obj, is_obj := v.(json.Object)
	if !is_obj do return nil
	t := get_str(obj, "_t")
	loc := get_loc(obj)

	switch t {
	case "FunctionDef":
		n := new(Func_Def, alloc)
		n.loc = loc
		n.name = clone_str(get_str(obj, "name"), alloc)
		n.args = conv_arguments(obj["args"], alloc)
		n.body = conv_stmts(obj["body"], alloc)
		n.decorator_list = conv_exprs(obj["decorator_list"], alloc)
		n.returns = conv_expr(obj["returns"], alloc)
		n.type_comment = clone_str(get_str(obj, "type_comment"), alloc)
		n.type_params = conv_type_params(obj["type_params"], alloc)
		return n
	case "AsyncFunctionDef":
		n := new(Async_Func_Def, alloc)
		n.loc = loc
		n.name = clone_str(get_str(obj, "name"), alloc)
		n.args = conv_arguments(obj["args"], alloc)
		n.body = conv_stmts(obj["body"], alloc)
		n.decorator_list = conv_exprs(obj["decorator_list"], alloc)
		n.returns = conv_expr(obj["returns"], alloc)
		n.type_comment = clone_str(get_str(obj, "type_comment"), alloc)
		n.type_params = conv_type_params(obj["type_params"], alloc)
		return n
	case "ClassDef":
		n := new(Class_Def, alloc)
		n.loc = loc
		n.name = clone_str(get_str(obj, "name"), alloc)
		n.bases = conv_exprs(obj["bases"], alloc)
		n.keywords = conv_keywords(obj["keywords"], alloc)
		n.body = conv_stmts(obj["body"], alloc)
		n.decorator_list = conv_exprs(obj["decorator_list"], alloc)
		n.type_params = conv_type_params(obj["type_params"], alloc)
		return n
	case "Return":
		n := new(Return_Stmt, alloc)
		n.loc = loc
		n.value = conv_expr(obj["value"], alloc)
		return n
	case "Delete":
		n := new(Delete_Stmt, alloc)
		n.loc = loc
		n.targets = conv_exprs(obj["targets"], alloc)
		return n
	case "Assign":
		n := new(Assign, alloc)
		n.loc = loc
		n.targets = conv_exprs(obj["targets"], alloc)
		n.value = conv_expr(obj["value"], alloc)
		n.type_comment = clone_str(get_str(obj, "type_comment"), alloc)
		return n
	case "AugAssign":
		n := new(Aug_Assign, alloc)
		n.loc = loc
		n.target = conv_expr(obj["target"], alloc)
		n.op = conv_binary_op(obj["op"])
		n.value = conv_expr(obj["value"], alloc)
		return n
	case "AnnAssign":
		n := new(Ann_Assign, alloc)
		n.loc = loc
		n.target = conv_expr(obj["target"], alloc)
		n.annotation = conv_expr(obj["annotation"], alloc)
		n.value = conv_expr(obj["value"], alloc)
		n.simple = get_int(obj, "simple") != 0
		return n
	case "For":
		n := new(For_Stmt, alloc)
		n.loc = loc
		n.target = conv_expr(obj["target"], alloc)
		n.iter = conv_expr(obj["iter"], alloc)
		n.body = conv_stmts(obj["body"], alloc)
		n.orelse = conv_stmts(obj["orelse"], alloc)
		n.type_comment = clone_str(get_str(obj, "type_comment"), alloc)
		return n
	case "AsyncFor":
		n := new(Async_For, alloc)
		n.loc = loc
		n.target = conv_expr(obj["target"], alloc)
		n.iter = conv_expr(obj["iter"], alloc)
		n.body = conv_stmts(obj["body"], alloc)
		n.orelse = conv_stmts(obj["orelse"], alloc)
		n.type_comment = clone_str(get_str(obj, "type_comment"), alloc)
		return n
	case "While":
		n := new(While_Stmt, alloc)
		n.loc = loc
		n.test = conv_expr(obj["test"], alloc)
		n.body = conv_stmts(obj["body"], alloc)
		n.orelse = conv_stmts(obj["orelse"], alloc)
		return n
	case "If":
		n := new(If_Stmt, alloc)
		n.loc = loc
		n.test = conv_expr(obj["test"], alloc)
		n.body = conv_stmts(obj["body"], alloc)
		n.orelse = conv_stmts(obj["orelse"], alloc)
		return n
	case "With":
		n := new(With_Stmt, alloc)
		n.loc = loc
		n.items = conv_with_items(obj["items"], alloc)
		n.body = conv_stmts(obj["body"], alloc)
		n.type_comment = clone_str(get_str(obj, "type_comment"), alloc)
		return n
	case "AsyncWith":
		n := new(Async_With, alloc)
		n.loc = loc
		n.items = conv_with_items(obj["items"], alloc)
		n.body = conv_stmts(obj["body"], alloc)
		n.type_comment = clone_str(get_str(obj, "type_comment"), alloc)
		return n
	case "Match":
		n := new(Match_Stmt, alloc)
		n.loc = loc
		n.subject = conv_expr(obj["subject"], alloc)
		n.cases = conv_match_cases(obj["cases"], alloc)
		return n
	case "Raise":
		n := new(Raise_Stmt, alloc)
		n.loc = loc
		n.exc = conv_expr(obj["exc"], alloc)
		n.cause = conv_expr(obj["cause"], alloc)
		return n
	case "Try":
		n := new(Try_Stmt, alloc)
		n.loc = loc
		n.body = conv_stmts(obj["body"], alloc)
		n.handlers = conv_exc_handlers(obj["handlers"], alloc)
		n.orelse = conv_stmts(obj["orelse"], alloc)
		n.finalbody = conv_stmts(obj["finalbody"], alloc)
		return n
	case "TryStar":
		n := new(Try_Star, alloc)
		n.loc = loc
		n.body = conv_stmts(obj["body"], alloc)
		n.handlers = conv_exc_handlers(obj["handlers"], alloc)
		n.orelse = conv_stmts(obj["orelse"], alloc)
		n.finalbody = conv_stmts(obj["finalbody"], alloc)
		return n
	case "Assert":
		n := new(Assert_Stmt, alloc)
		n.loc = loc
		n.test = conv_expr(obj["test"], alloc)
		n.msg = conv_expr(obj["msg"], alloc)
		return n
	case "Import":
		n := new(Import_Stmt, alloc)
		n.loc = loc
		n.names = conv_aliases(obj["names"], alloc)
		return n
	case "ImportFrom":
		n := new(Import_From, alloc)
		n.loc = loc
		n.module = clone_str(get_str(obj, "module"), alloc)
		n.names = conv_aliases(obj["names"], alloc)
		n.level = int(get_int(obj, "level"))
		return n
	case "Global":
		n := new(Global_Stmt, alloc)
		n.loc = loc
		n.names = conv_strings(obj["names"], alloc)
		return n
	case "Nonlocal":
		n := new(Nonlocal_Stmt, alloc)
		n.loc = loc
		n.names = conv_strings(obj["names"], alloc)
		return n
	case "Expr":
		n := new(Expr_Stmt, alloc)
		n.loc = loc
		n.value = conv_expr(obj["value"], alloc)
		return n
	case "Pass":
		n := new(Pass_Stmt, alloc)
		n.loc = loc
		return n
	case "Break":
		n := new(Break_Stmt, alloc)
		n.loc = loc
		return n
	case "Continue":
		n := new(Continue_Stmt, alloc)
		n.loc = loc
		return n
	case "TypeAlias":
		n := new(Type_Alias_Stmt, alloc)
		n.loc = loc
		n.name = conv_expr(obj["name"], alloc)
		n.type_params = conv_type_params(obj["type_params"], alloc)
		n.value = conv_expr(obj["value"], alloc)
		return n
	}
	return nil
}

// ==================== Expression Converter ====================

conv_expr :: proc(v: json.Value, alloc: mem.Allocator) -> Expr {
	obj, is_obj := v.(json.Object)
	if !is_obj do return nil
	t := get_str(obj, "_t")
	loc := get_loc(obj)

	switch t {
	case "BoolOp":
		n := new(Bool_Op_Expr, alloc)
		n.loc = loc
		n.op = conv_bool_op(obj["op"])
		n.values = conv_exprs(obj["values"], alloc)
		return n
	case "NamedExpr":
		n := new(Named_Expr, alloc)
		n.loc = loc
		n.target = conv_expr(obj["target"], alloc)
		n.value = conv_expr(obj["value"], alloc)
		return n
	case "BinOp":
		n := new(Bin_Op_Expr, alloc)
		n.loc = loc
		n.left = conv_expr(obj["left"], alloc)
		n.op = conv_binary_op(obj["op"])
		n.right = conv_expr(obj["right"], alloc)
		return n
	case "UnaryOp":
		n := new(Unary_Op_Expr, alloc)
		n.loc = loc
		n.op = conv_unary_op(obj["op"])
		n.operand = conv_expr(obj["operand"], alloc)
		return n
	case "Lambda":
		n := new(Lambda_Expr, alloc)
		n.loc = loc
		n.args = conv_arguments(obj["args"], alloc)
		n.body = conv_expr(obj["body"], alloc)
		return n
	case "IfExp":
		n := new(If_Expr, alloc)
		n.loc = loc
		n.test = conv_expr(obj["test"], alloc)
		n.body = conv_expr(obj["body"], alloc)
		n.orelse = conv_expr(obj["orelse"], alloc)
		return n
	case "Dict":
		n := new(Dict_Expr, alloc)
		n.loc = loc
		n.keys = conv_exprs(obj["keys"], alloc)
		n.values = conv_exprs(obj["values"], alloc)
		return n
	case "Set":
		n := new(Set_Expr, alloc)
		n.loc = loc
		n.elts = conv_exprs(obj["elts"], alloc)
		return n
	case "ListComp":
		n := new(List_Comp, alloc)
		n.loc = loc
		n.elt = conv_expr(obj["elt"], alloc)
		n.generators = conv_comprehensions(obj["generators"], alloc)
		return n
	case "SetComp":
		n := new(Set_Comp, alloc)
		n.loc = loc
		n.elt = conv_expr(obj["elt"], alloc)
		n.generators = conv_comprehensions(obj["generators"], alloc)
		return n
	case "DictComp":
		n := new(Dict_Comp, alloc)
		n.loc = loc
		n.key = conv_expr(obj["key"], alloc)
		n.value = conv_expr(obj["value"], alloc)
		n.generators = conv_comprehensions(obj["generators"], alloc)
		return n
	case "GeneratorExp":
		n := new(Generator_Expr, alloc)
		n.loc = loc
		n.elt = conv_expr(obj["elt"], alloc)
		n.generators = conv_comprehensions(obj["generators"], alloc)
		return n
	case "Await":
		n := new(Await_Expr, alloc)
		n.loc = loc
		n.value = conv_expr(obj["value"], alloc)
		return n
	case "Yield":
		n := new(Yield_Expr, alloc)
		n.loc = loc
		n.value = conv_expr(obj["value"], alloc)
		return n
	case "YieldFrom":
		n := new(Yield_From_Expr, alloc)
		n.loc = loc
		n.value = conv_expr(obj["value"], alloc)
		return n
	case "Compare":
		n := new(Compare_Expr, alloc)
		n.loc = loc
		n.left = conv_expr(obj["left"], alloc)
		n.ops = conv_cmp_ops(obj["ops"], alloc)
		n.comparators = conv_exprs(obj["comparators"], alloc)
		return n
	case "Call":
		n := new(Call_Expr, alloc)
		n.loc = loc
		n.func = conv_expr(obj["func"], alloc)
		n.args = conv_exprs(obj["args"], alloc)
		n.keywords = conv_keywords(obj["keywords"], alloc)
		return n
	case "FormattedValue":
		n := new(Formatted_Value, alloc)
		n.loc = loc
		n.value = conv_expr(obj["value"], alloc)
		n.conversion = i32(get_int(obj, "conversion"))
		n.format_spec = conv_expr(obj["format_spec"], alloc)
		return n
	case "JoinedStr":
		n := new(Joined_Str, alloc)
		n.loc = loc
		n.values = conv_exprs(obj["values"], alloc)
		return n
	case "Constant":
		n := new(Constant_Expr, alloc)
		n.loc = loc
		n.value = conv_constant_value(obj["value"], alloc)
		return n
	case "Attribute":
		n := new(Attribute_Expr, alloc)
		n.loc = loc
		n.value = conv_expr(obj["value"], alloc)
		n.attr = clone_str(get_str(obj, "attr"), alloc)
		n.ctx = conv_expr_context(obj["ctx"])
		return n
	case "Subscript":
		n := new(Subscript_Expr, alloc)
		n.loc = loc
		n.value = conv_expr(obj["value"], alloc)
		n.slice = conv_expr(obj["slice"], alloc)
		n.ctx = conv_expr_context(obj["ctx"])
		return n
	case "Starred":
		n := new(Starred_Expr, alloc)
		n.loc = loc
		n.value = conv_expr(obj["value"], alloc)
		n.ctx = conv_expr_context(obj["ctx"])
		return n
	case "Name":
		n := new(Name_Expr, alloc)
		n.loc = loc
		n.id = clone_str(get_str(obj, "id"), alloc)
		n.ctx = conv_expr_context(obj["ctx"])
		return n
	case "List":
		n := new(List_Expr, alloc)
		n.loc = loc
		n.elts = conv_exprs(obj["elts"], alloc)
		n.ctx = conv_expr_context(obj["ctx"])
		return n
	case "Tuple":
		n := new(Tuple_Expr, alloc)
		n.loc = loc
		n.elts = conv_exprs(obj["elts"], alloc)
		n.ctx = conv_expr_context(obj["ctx"])
		return n
	case "Slice":
		n := new(Slice_Expr, alloc)
		n.loc = loc
		n.lower = conv_expr(obj["lower"], alloc)
		n.upper = conv_expr(obj["upper"], alloc)
		n.step = conv_expr(obj["step"], alloc)
		return n
	}
	return nil
}

// ==================== Pattern Converter ====================

conv_pattern :: proc(v: json.Value, alloc: mem.Allocator) -> Pattern {
	obj, is_obj := v.(json.Object)
	if !is_obj do return nil
	t := get_str(obj, "_t")
	loc := get_loc(obj)

	switch t {
	case "MatchValue":
		n := new(Match_Value, alloc)
		n.loc = loc
		n.value = conv_expr(obj["value"], alloc)
		return n
	case "MatchSingleton":
		n := new(Match_Singleton, alloc)
		n.loc = loc
		n.value = conv_constant_value(obj["value"], alloc)
		return n
	case "MatchSequence":
		n := new(Match_Sequence, alloc)
		n.loc = loc
		n.patterns = conv_patterns(obj["patterns"], alloc)
		return n
	case "MatchMapping":
		n := new(Match_Mapping, alloc)
		n.loc = loc
		n.keys = conv_exprs(obj["keys"], alloc)
		n.patterns = conv_patterns(obj["patterns"], alloc)
		n.rest = clone_str(get_str(obj, "rest"), alloc)
		return n
	case "MatchClass":
		n := new(Match_Class, alloc)
		n.loc = loc
		n.cls = conv_expr(obj["cls"], alloc)
		n.patterns = conv_patterns(obj["patterns"], alloc)
		n.kwd_attrs = conv_strings(obj["kwd_attrs"], alloc)
		n.kwd_patterns = conv_patterns(obj["kwd_patterns"], alloc)
		return n
	case "MatchStar":
		n := new(Match_Star, alloc)
		n.loc = loc
		n.name = clone_str(get_str(obj, "name"), alloc)
		return n
	case "MatchAs":
		n := new(Match_As, alloc)
		n.loc = loc
		n.pattern = conv_pattern(obj["pattern"], alloc)
		n.name = clone_str(get_str(obj, "name"), alloc)
		return n
	case "MatchOr":
		n := new(Match_Or, alloc)
		n.loc = loc
		n.patterns = conv_patterns(obj["patterns"], alloc)
		return n
	}
	return nil
}

// ==================== Type Param Converter ====================

conv_type_param :: proc(v: json.Value, alloc: mem.Allocator) -> Type_Param {
	obj, is_obj := v.(json.Object)
	if !is_obj do return nil
	t := get_str(obj, "_t")
	loc := get_loc(obj)

	switch t {
	case "TypeVar":
		n := new(Type_Var_Param, alloc)
		n.loc = loc
		n.name = clone_str(get_str(obj, "name"), alloc)
		n.bound = conv_expr(obj["bound"], alloc)
		return n
	case "ParamSpec":
		n := new(Param_Spec_Param, alloc)
		n.loc = loc
		n.name = clone_str(get_str(obj, "name"), alloc)
		return n
	case "TypeVarTuple":
		n := new(Type_Var_Tuple_Param, alloc)
		n.loc = loc
		n.name = clone_str(get_str(obj, "name"), alloc)
		return n
	}
	return nil
}

// ==================== Auxiliary Converters ====================

conv_arguments :: proc(v: json.Value, alloc: mem.Allocator) -> Arguments {
	obj, is_obj := v.(json.Object)
	if !is_obj do return {}
	return Arguments{
		posonlyargs = conv_args(obj["posonlyargs"], alloc),
		args        = conv_args(obj["args"], alloc),
		vararg      = conv_arg_ptr(obj["vararg"], alloc),
		kwonlyargs  = conv_args(obj["kwonlyargs"], alloc),
		kw_defaults = conv_exprs(obj["kw_defaults"], alloc),
		kwarg       = conv_arg_ptr(obj["kwarg"], alloc),
		defaults    = conv_exprs(obj["defaults"], alloc),
	}
}

conv_arg_ptr :: proc(v: json.Value, alloc: mem.Allocator) -> ^Arg {
	obj, is_obj := v.(json.Object)
	if !is_obj do return nil
	loc := get_loc(obj)
	a := new(Arg, alloc)
	a.loc = loc
	a.arg = clone_str(get_str(obj, "arg"), alloc)
	a.annotation = conv_expr(obj["annotation"], alloc)
	a.type_comment = clone_str(get_str(obj, "type_comment"), alloc)
	return a
}

conv_args :: proc(v: json.Value, alloc: mem.Allocator) -> []Arg {
	arr, is_arr := v.(json.Array)
	if !is_arr do return nil
	result := make([]Arg, len(arr), alloc)
	for item, i in arr {
		obj, is_obj := item.(json.Object)
		if !is_obj do continue
		loc := get_loc(obj)
		result[i].loc = loc
		result[i].arg = clone_str(get_str(obj, "arg"), alloc)
		result[i].annotation = conv_expr(obj["annotation"], alloc)
		result[i].type_comment = clone_str(get_str(obj, "type_comment"), alloc)
	}
	return result
}

conv_keyword :: proc(v: json.Value, alloc: mem.Allocator) -> Keyword {
	obj, is_obj := v.(json.Object)
	if !is_obj do return {}
	return Keyword{
		base  = {loc = get_loc(obj)},
		arg   = clone_str(get_str(obj, "arg"), alloc),
		value = conv_expr(obj["value"], alloc),
	}
}

conv_keywords :: proc(v: json.Value, alloc: mem.Allocator) -> []Keyword {
	arr, is_arr := v.(json.Array)
	if !is_arr do return nil
	result := make([]Keyword, len(arr), alloc)
	for item, i in arr {
		result[i] = conv_keyword(item, alloc)
	}
	return result
}

conv_alias :: proc(v: json.Value, alloc: mem.Allocator) -> Alias {
	obj, is_obj := v.(json.Object)
	if !is_obj do return {}
	return Alias{
		base   = {loc = get_loc(obj)},
		name   = clone_str(get_str(obj, "name"), alloc),
		asname = clone_str(get_str(obj, "asname"), alloc),
	}
}

conv_aliases :: proc(v: json.Value, alloc: mem.Allocator) -> []Alias {
	arr, is_arr := v.(json.Array)
	if !is_arr do return nil
	result := make([]Alias, len(arr), alloc)
	for item, i in arr {
		result[i] = conv_alias(item, alloc)
	}
	return result
}

conv_with_item :: proc(v: json.Value, alloc: mem.Allocator) -> With_Item {
	obj, is_obj := v.(json.Object)
	if !is_obj do return {}
	return With_Item{
		context_expr  = conv_expr(obj["context_expr"], alloc),
		optional_vars = conv_expr(obj["optional_vars"], alloc),
	}
}

conv_with_items :: proc(v: json.Value, alloc: mem.Allocator) -> []With_Item {
	arr, is_arr := v.(json.Array)
	if !is_arr do return nil
	result := make([]With_Item, len(arr), alloc)
	for item, i in arr {
		result[i] = conv_with_item(item, alloc)
	}
	return result
}

conv_match_case :: proc(v: json.Value, alloc: mem.Allocator) -> Match_Case {
	obj, is_obj := v.(json.Object)
	if !is_obj do return {}
	return Match_Case{
		pattern = conv_pattern(obj["pattern"], alloc),
		guard   = conv_expr(obj["guard"], alloc),
		body    = conv_stmts(obj["body"], alloc),
	}
}

conv_match_cases :: proc(v: json.Value, alloc: mem.Allocator) -> []Match_Case {
	arr, is_arr := v.(json.Array)
	if !is_arr do return nil
	result := make([]Match_Case, len(arr), alloc)
	for item, i in arr {
		result[i] = conv_match_case(item, alloc)
	}
	return result
}

conv_exc_handler :: proc(v: json.Value, alloc: mem.Allocator) -> Exception_Handler {
	obj, is_obj := v.(json.Object)
	if !is_obj do return {}
	return Exception_Handler{
		base = {loc = get_loc(obj)},
		type = conv_expr(obj["type"], alloc),
		name = clone_str(get_str(obj, "name"), alloc),
		body = conv_stmts(obj["body"], alloc),
	}
}

conv_exc_handlers :: proc(v: json.Value, alloc: mem.Allocator) -> []Exception_Handler {
	arr, is_arr := v.(json.Array)
	if !is_arr do return nil
	result := make([]Exception_Handler, len(arr), alloc)
	for item, i in arr {
		result[i] = conv_exc_handler(item, alloc)
	}
	return result
}

conv_comprehension :: proc(v: json.Value, alloc: mem.Allocator) -> Comprehension {
	obj, is_obj := v.(json.Object)
	if !is_obj do return {}
	return Comprehension{
		target   = conv_expr(obj["target"], alloc),
		iter     = conv_expr(obj["iter"], alloc),
		ifs      = conv_exprs(obj["ifs"], alloc),
		is_async = get_int(obj, "is_async") != 0,
	}
}

conv_comprehensions :: proc(v: json.Value, alloc: mem.Allocator) -> []Comprehension {
	arr, is_arr := v.(json.Array)
	if !is_arr do return nil
	result := make([]Comprehension, len(arr), alloc)
	for item, i in arr {
		result[i] = conv_comprehension(item, alloc)
	}
	return result
}

conv_type_ignore :: proc(v: json.Value, alloc: mem.Allocator) -> Type_Ignore {
	obj, is_obj := v.(json.Object)
	if !is_obj do return {}
	return Type_Ignore{
		lineno = i32(get_int(obj, "lineno")),
		tag    = clone_str(get_str(obj, "tag"), alloc),
	}
}

conv_type_ignores :: proc(v: json.Value, alloc: mem.Allocator) -> []Type_Ignore {
	arr, is_arr := v.(json.Array)
	if !is_arr do return nil
	result := make([]Type_Ignore, len(arr), alloc)
	for item, i in arr {
		result[i] = conv_type_ignore(item, alloc)
	}
	return result
}

// ==================== Constant Value ====================

conv_constant_value :: proc(v: json.Value, alloc: mem.Allocator) -> Constant_Value {
	switch val in v {
	case json.Null:
		return Const_None{}
	case json.Boolean:
		return bool(val)
	case json.Integer:
		return i64(val)
	case json.Float:
		return f64(val)
	case json.String:
		return clone_str(string(val), alloc)
	case json.Object:
		// Check for special markers from the Python serializer
		if _, has := val["_ellipsis"]; has {
			return Const_Ellipsis{}
		}
		if comp_val, has := val["_complex"]; has {
			arr, is_arr := comp_val.(json.Array)
			if is_arr && len(arr) >= 2 {
				return Const_Complex{real = to_f64(arr[0]), imag = to_f64(arr[1])}
			}
		}
		if b64_val, has := val["_bytes"]; has {
			b64_str, is_str := b64_val.(json.String)
			if is_str {
				// Decode base64 from CPython's AST serializer
				decoded, decode_err := base64.decode(b64_str, allocator = alloc)
				if decode_err == nil {
					return Const_Bytes{data = decoded}
				}
				// Fallback: store raw on decode failure
				buf := make([]u8, len(b64_str), alloc)
				copy(buf, b64_str)
				return Const_Bytes{data = buf}
			}
		}
	case json.Array:
		// frozenset — not supported yet
	}
	return nil
}
