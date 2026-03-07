package parser

// Python AST node types — mirrors CPython's ast module.
// All nodes are arena-allocated. Unions use pointer variants for compact size.

Src_Loc :: struct {
	line:     i32,
	col:      i32,
	end_line: i32,
	end_col:  i32,
}

Node_Base :: struct {
	loc: Src_Loc,
	node_id: u32,
}

// ==================== Top-level ====================

Module :: struct {
	using base:   Node_Base,
	body:         []Stmt,
	type_ignores: []Type_Ignore,
}

// ==================== Statements ====================

Stmt :: union {
	^Func_Def,
	^Async_Func_Def,
	^Class_Def,
	^Return_Stmt,
	^Delete_Stmt,
	^Assign,
	^Aug_Assign,
	^Ann_Assign,
	^For_Stmt,
	^Async_For,
	^While_Stmt,
	^If_Stmt,
	^With_Stmt,
	^Async_With,
	^Match_Stmt,
	^Raise_Stmt,
	^Try_Stmt,
	^Try_Star,
	^Assert_Stmt,
	^Import_Stmt,
	^Import_From,
	^Global_Stmt,
	^Nonlocal_Stmt,
	^Expr_Stmt,
	^Pass_Stmt,
	^Break_Stmt,
	^Continue_Stmt,
	^Type_Alias_Stmt,
}

Func_Def :: struct {
	using base:     Node_Base,
	name:           string,
	args:           Arguments,
	body:           []Stmt,
	decorator_list: []Expr,
	returns:        Expr,
	type_comment:   string,
	type_params:    []Type_Param,
}

Async_Func_Def :: struct {
	using base:     Node_Base,
	name:           string,
	args:           Arguments,
	body:           []Stmt,
	decorator_list: []Expr,
	returns:        Expr,
	type_comment:   string,
	type_params:    []Type_Param,
}

Class_Def :: struct {
	using base:     Node_Base,
	name:           string,
	bases:          []Expr,
	keywords:       []Keyword,
	body:           []Stmt,
	decorator_list: []Expr,
	type_params:    []Type_Param,
}

Return_Stmt :: struct {
	using base: Node_Base,
	value:      Expr,
}

Delete_Stmt :: struct {
	using base: Node_Base,
	targets:    []Expr,
}

Assign :: struct {
	using base:   Node_Base,
	targets:      []Expr,
	value:        Expr,
	type_comment: string,
}

Aug_Assign :: struct {
	using base: Node_Base,
	target:     Expr,
	op:         Binary_Op,
	value:      Expr,
}

Ann_Assign :: struct {
	using base: Node_Base,
	target:     Expr,
	annotation: Expr,
	value:      Expr,
	simple:     bool,
}

For_Stmt :: struct {
	using base:   Node_Base,
	target:       Expr,
	iter:         Expr,
	body:         []Stmt,
	orelse:       []Stmt,
	type_comment: string,
}

Async_For :: struct {
	using base:   Node_Base,
	target:       Expr,
	iter:         Expr,
	body:         []Stmt,
	orelse:       []Stmt,
	type_comment: string,
}

While_Stmt :: struct {
	using base: Node_Base,
	test:       Expr,
	body:       []Stmt,
	orelse:     []Stmt,
}

If_Stmt :: struct {
	using base: Node_Base,
	test:       Expr,
	body:       []Stmt,
	orelse:     []Stmt,
}

With_Stmt :: struct {
	using base:   Node_Base,
	items:        []With_Item,
	body:         []Stmt,
	type_comment: string,
}

Async_With :: struct {
	using base:   Node_Base,
	items:        []With_Item,
	body:         []Stmt,
	type_comment: string,
}

Match_Stmt :: struct {
	using base: Node_Base,
	subject:    Expr,
	cases:      []Match_Case,
}

Raise_Stmt :: struct {
	using base: Node_Base,
	exc:        Expr,
	cause:      Expr,
}

Try_Stmt :: struct {
	using base: Node_Base,
	body:       []Stmt,
	handlers:   []Exception_Handler,
	orelse:     []Stmt,
	finalbody:  []Stmt,
}

Try_Star :: struct {
	using base: Node_Base,
	body:       []Stmt,
	handlers:   []Exception_Handler,
	orelse:     []Stmt,
	finalbody:  []Stmt,
}

Assert_Stmt :: struct {
	using base: Node_Base,
	test:       Expr,
	msg:        Expr,
}

Import_Stmt :: struct {
	using base: Node_Base,
	names:      []Alias,
}

Import_From :: struct {
	using base: Node_Base,
	module:     string,
	names:      []Alias,
	level:      int,
}

Global_Stmt :: struct {
	using base: Node_Base,
	names:      []string,
}

Nonlocal_Stmt :: struct {
	using base: Node_Base,
	names:      []string,
}

Expr_Stmt :: struct {
	using base: Node_Base,
	value:      Expr,
}

Pass_Stmt :: struct {
	using base: Node_Base,
}

Break_Stmt :: struct {
	using base: Node_Base,
}

Continue_Stmt :: struct {
	using base: Node_Base,
}

Type_Alias_Stmt :: struct {
	using base:  Node_Base,
	name:        Expr,
	type_params: []Type_Param,
	value:       Expr,
}

// ==================== Expressions ====================

Expr :: union {
	^Bool_Op_Expr,
	^Named_Expr,
	^Bin_Op_Expr,
	^Unary_Op_Expr,
	^Lambda_Expr,
	^If_Expr,
	^Dict_Expr,
	^Set_Expr,
	^List_Comp,
	^Set_Comp,
	^Dict_Comp,
	^Generator_Expr,
	^Await_Expr,
	^Yield_Expr,
	^Yield_From_Expr,
	^Compare_Expr,
	^Call_Expr,
	^Formatted_Value,
	^Joined_Str,
	^Constant_Expr,
	^Attribute_Expr,
	^Subscript_Expr,
	^Starred_Expr,
	^Name_Expr,
	^List_Expr,
	^Tuple_Expr,
	^Slice_Expr,
}

Bool_Op_Expr :: struct {
	using base: Node_Base,
	op:         Bool_Op_Kind,
	values:     []Expr,
}

Named_Expr :: struct {
	using base: Node_Base,
	target:     Expr,
	value:      Expr,
}

Bin_Op_Expr :: struct {
	using base: Node_Base,
	left:       Expr,
	op:         Binary_Op,
	right:      Expr,
}

Unary_Op_Expr :: struct {
	using base: Node_Base,
	op:         Unary_Op,
	operand:    Expr,
}

Lambda_Expr :: struct {
	using base: Node_Base,
	args:       Arguments,
	body:       Expr,
}

If_Expr :: struct {
	using base: Node_Base,
	test:       Expr,
	body:       Expr,
	orelse:     Expr,
}

Dict_Expr :: struct {
	using base: Node_Base,
	keys:       []Expr,
	values:     []Expr,
}

Set_Expr :: struct {
	using base: Node_Base,
	elts:       []Expr,
}

List_Comp :: struct {
	using base: Node_Base,
	elt:        Expr,
	generators: []Comprehension,
}

Set_Comp :: struct {
	using base: Node_Base,
	elt:        Expr,
	generators: []Comprehension,
}

Dict_Comp :: struct {
	using base: Node_Base,
	key:        Expr,
	value:      Expr,
	generators: []Comprehension,
}

Generator_Expr :: struct {
	using base: Node_Base,
	elt:        Expr,
	generators: []Comprehension,
}

Await_Expr :: struct {
	using base: Node_Base,
	value:      Expr,
}

Yield_Expr :: struct {
	using base: Node_Base,
	value:      Expr,
}

Yield_From_Expr :: struct {
	using base: Node_Base,
	value:      Expr,
}

Compare_Expr :: struct {
	using base:  Node_Base,
	left:        Expr,
	ops:         []Cmp_Op,
	comparators: []Expr,
}

Call_Expr :: struct {
	using base: Node_Base,
	func:       Expr,
	args:       []Expr,
	keywords:   []Keyword,
}

Formatted_Value :: struct {
	using base:  Node_Base,
	value:       Expr,
	conversion:  i32,
	format_spec: Expr,
}

Joined_Str :: struct {
	using base: Node_Base,
	values:     []Expr,
}

Const_None :: struct {}
Const_Ellipsis :: struct {}
Const_Complex :: struct {
	real, imag: f64,
}
Const_Bytes :: struct {
	data: []u8,
}

Constant_Value :: union {
	Const_None,
	Const_Ellipsis,
	bool,
	i64,
	f64,
	Const_Complex,
	string,
	Const_Bytes,
}

Constant_Expr :: struct {
	using base: Node_Base,
	value:      Constant_Value,
}

Attribute_Expr :: struct {
	using base: Node_Base,
	value:      Expr,
	attr:       string,
	ctx:        Expr_Context,
}

Subscript_Expr :: struct {
	using base: Node_Base,
	value:      Expr,
	slice:      Expr,
	ctx:        Expr_Context,
}

Starred_Expr :: struct {
	using base: Node_Base,
	value:      Expr,
	ctx:        Expr_Context,
}

Name_Expr :: struct {
	using base: Node_Base,
	id:         string,
	ctx:        Expr_Context,
}

List_Expr :: struct {
	using base: Node_Base,
	elts:       []Expr,
	ctx:        Expr_Context,
}

Tuple_Expr :: struct {
	using base: Node_Base,
	elts:       []Expr,
	ctx:        Expr_Context,
}

Slice_Expr :: struct {
	using base: Node_Base,
	lower:      Expr,
	upper:      Expr,
	step:       Expr,
}

// ==================== Patterns (match/case) ====================

Pattern :: union {
	^Match_Value,
	^Match_Singleton,
	^Match_Sequence,
	^Match_Mapping,
	^Match_Class,
	^Match_Star,
	^Match_As,
	^Match_Or,
}

Match_Value :: struct {
	using base: Node_Base,
	value:      Expr,
}

Match_Singleton :: struct {
	using base: Node_Base,
	value:      Constant_Value,
}

Match_Sequence :: struct {
	using base: Node_Base,
	patterns:   []Pattern,
}

Match_Mapping :: struct {
	using base: Node_Base,
	keys:       []Expr,
	patterns:   []Pattern,
	rest:       string,
}

Match_Class :: struct {
	using base:   Node_Base,
	cls:          Expr,
	patterns:     []Pattern,
	kwd_attrs:    []string,
	kwd_patterns: []Pattern,
}

Match_Star :: struct {
	using base: Node_Base,
	name:       string,
}

Match_As :: struct {
	using base: Node_Base,
	pattern:    Pattern,
	name:       string,
}

Match_Or :: struct {
	using base: Node_Base,
	patterns:   []Pattern,
}

// ==================== Type Parameters (Python 3.12+) ====================

Type_Param :: union {
	^Type_Var_Param,
	^Param_Spec_Param,
	^Type_Var_Tuple_Param,
}

Type_Var_Param :: struct {
	using base: Node_Base,
	name:       string,
	bound:      Expr,
}

Param_Spec_Param :: struct {
	using base: Node_Base,
	name:       string,
}

Type_Var_Tuple_Param :: struct {
	using base: Node_Base,
	name:       string,
}

// ==================== Auxiliary Types ====================

Arguments :: struct {
	posonlyargs: []Arg,
	args:        []Arg,
	vararg:      ^Arg,
	kwonlyargs:  []Arg,
	kw_defaults: []Expr,
	kwarg:       ^Arg,
	defaults:    []Expr,
}

Arg :: struct {
	using base:   Node_Base,
	arg:          string,
	annotation:   Expr,
	type_comment: string,
}

Keyword :: struct {
	using base: Node_Base,
	arg:        string,
	value:      Expr,
}

Alias :: struct {
	using base: Node_Base,
	name:       string,
	asname:     string,
}

With_Item :: struct {
	context_expr:  Expr,
	optional_vars: Expr,
}

Match_Case :: struct {
	pattern: Pattern,
	guard:   Expr,
	body:    []Stmt,
}

Exception_Handler :: struct {
	using base: Node_Base,
	type:       Expr,
	name:       string,
	body:       []Stmt,
}

Comprehension :: struct {
	target:   Expr,
	iter:     Expr,
	ifs:      []Expr,
	is_async: bool,
}

Type_Ignore :: struct {
	lineno: i32,
	tag:    string,
}

// ==================== Error Types ====================

Bridge_Error :: struct {
	msg: string,
}

Syntax_Error :: struct {
	msg:  string,
	file: string,
	line: int,
	col:  int,
}

Parse_Error :: union {
	Bridge_Error,
	Syntax_Error,
}
