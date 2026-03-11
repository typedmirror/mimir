package migration

import "core:fmt"
import "core:strings"
import parser "mimir:parser"
import core "mimir:core"

// ==================== MIG001: Union[X, Y] → X | Y ====================

check_union_syntax :: proc(ctx: ^Migration_Context) {
	walk_annotations(ctx, ctx.module.body, "MIG001", proc(ctx: ^Migration_Context, code: string, expr: parser.Expr) {
		sub, ok := expr.(^parser.Subscript_Expr)
		if !ok { return }
		name, is_name := sub.value.(^parser.Name_Expr)
		if !is_name { return }
		orig, found := ctx.bind_result.typing_names[name.id]
		if !found { return }
		if orig == "Union" {
			emit(ctx, code, sub.loc,
				"Union[X, Y] can be written as X | Y",
				"PEP 604 introduced the X | Y syntax as a cleaner alternative to Union",
				"Replace Union[...] with X | Y",
			)
		}
	})
}

// ==================== MIG002: Optional[X] → X | None ====================

check_optional_syntax :: proc(ctx: ^Migration_Context) {
	walk_annotations(ctx, ctx.module.body, "MIG002", proc(ctx: ^Migration_Context, code: string, expr: parser.Expr) {
		sub, ok := expr.(^parser.Subscript_Expr)
		if !ok { return }
		name, is_name := sub.value.(^parser.Name_Expr)
		if !is_name { return }
		orig, found := ctx.bind_result.typing_names[name.id]
		if !found { return }
		if orig == "Optional" {
			emit(ctx, code, sub.loc,
				"Optional[X] can be written as X | None",
				"PEP 604 introduced the X | None syntax as a cleaner alternative to Optional",
				"Replace Optional[X] with X | None",
			)
		}
	})
}

// ==================== MIG003: typing.List/Dict/Set/Tuple/FrozenSet → builtins ====================

BUILTIN_GENERIC_MAP := [?]struct{typing_name: string, builtin: string}{
	{"Dict",      "dict"},
	{"List",      "list"},
	{"Tuple",     "tuple"},
	{"Set",       "set"},
	{"FrozenSet", "frozenset"},
}

check_builtin_generics :: proc(ctx: ^Migration_Context) {
	walk_annotations(ctx, ctx.module.body, "MIG003", proc(ctx: ^Migration_Context, code: string, expr: parser.Expr) {
		sub, ok := expr.(^parser.Subscript_Expr)
		if !ok { return }
		name, is_name := sub.value.(^parser.Name_Expr)
		if !is_name { return }
		orig, found := ctx.bind_result.typing_names[name.id]
		if !found { return }
		for entry in BUILTIN_GENERIC_MAP {
			if orig == entry.typing_name {
				what := fmt.tprintf("typing.%s can be written as %s", entry.typing_name, entry.builtin)
				fix := fmt.tprintf("Replace %s[...] with %s[...]", entry.typing_name, entry.builtin)
				emit(ctx, code, sub.loc, what,
					"PEP 585 made built-in types directly subscriptable",
					fix,
				)
				return
			}
		}
	})
}

// ==================== MIG004: typing.Type[X] → type[X] ====================

check_builtin_type :: proc(ctx: ^Migration_Context) {
	walk_annotations(ctx, ctx.module.body, "MIG004", proc(ctx: ^Migration_Context, code: string, expr: parser.Expr) {
		sub, ok := expr.(^parser.Subscript_Expr)
		if !ok { return }
		name, is_name := sub.value.(^parser.Name_Expr)
		if !is_name { return }
		orig, found := ctx.bind_result.typing_names[name.id]
		if !found { return }
		if orig == "Type" {
			emit(ctx, code, sub.loc,
				"typing.Type[X] can be written as type[X]",
				"PEP 585 made type directly subscriptable",
				"Replace Type[X] with type[X]",
			)
		}
	})
}

// ==================== MIG005: isinstance(x, (A, B)) → isinstance(x, A | B) ====================

check_isinstance_union :: proc(ctx: ^Migration_Context) {
	walk_exprs(ctx, ctx.module.body, proc(ctx: ^Migration_Context, expr: parser.Expr) {
		call, ok := expr.(^parser.Call_Expr)
		if !ok { return }
		fname, is_name := call.func.(^parser.Name_Expr)
		if !is_name { return }
		if fname.id != "isinstance" && fname.id != "issubclass" { return }
		if len(call.args) < 2 { return }
		// Check if second arg is a tuple literal
		_, is_tuple := call.args[1].(^parser.Tuple_Expr)
		if !is_tuple { return }
		what := fmt.tprintf("%s() tuple argument can use X | Y syntax", fname.id)
		fix := fmt.tprintf("Replace %s(x, (A, B)) with %s(x, A | B)", fname.id, fname.id)
		emit(ctx, "MIG005", call.loc, what,
			"PEP 604 allows union syntax in isinstance/issubclass",
			fix,
		)
	})
}

// ==================== MIG006: collections.OrderedDict → dict ====================

check_ordered_dict :: proc(ctx: ^Migration_Context) {
	// Check imports
	for stmt in ctx.module.body {
		#partial switch s in stmt {
		case ^parser.Import_From:
			if s.module == "collections" {
				for alias in s.names {
					if alias.name == "OrderedDict" {
						emit(ctx, "MIG006", s.loc,
							"collections.OrderedDict can be replaced with dict",
							"dict preserves insertion order since Python 3.7",
							"Replace OrderedDict with dict (unless you need OrderedDict-specific methods)",
						)
					}
				}
			}
		}
	}
	// Check attribute access: collections.OrderedDict
	walk_exprs(ctx, ctx.module.body, proc(ctx: ^Migration_Context, expr: parser.Expr) {
		attr, ok := expr.(^parser.Attribute_Expr)
		if !ok { return }
		name, is_name := attr.value.(^parser.Name_Expr)
		if !is_name { return }
		if name.id == "collections" && attr.attr == "OrderedDict" {
			emit(ctx, "MIG006", attr.loc,
				"collections.OrderedDict can be replaced with dict",
				"dict preserves insertion order since Python 3.7",
				"Replace OrderedDict with dict (unless you need OrderedDict-specific methods)",
			)
		}
	})
}

// ==================== MIG007: collections.* → collections.abc.* ====================

COLLECTIONS_ABC_NAMES := [?]string{
	"MutableMapping", "MutableSequence", "MutableSet",
	"Mapping", "Sequence", "Set",
	"Iterable", "Iterator", "Generator",
	"Callable", "Coroutine", "AsyncIterable", "AsyncIterator", "AsyncGenerator",
	"Hashable", "Sized", "Container", "Collection",
	"Reversible", "MappingView", "ItemsView", "KeysView", "ValuesView",
	"Awaitable",
}

check_collections_abc :: proc(ctx: ^Migration_Context) {
	for stmt in ctx.module.body {
		#partial switch s in stmt {
		case ^parser.Import_From:
			if s.module == "collections" {
				for alias in s.names {
					for abc_name in COLLECTIONS_ABC_NAMES {
						if alias.name == abc_name {
							what := fmt.tprintf("collections.%s moved to collections.abc", abc_name)
							fix := fmt.tprintf("Use 'from collections.abc import %s'", abc_name)
							emit(ctx, "MIG007", s.loc, what,
								"Abstract base classes were removed from collections in Python 3.10",
								fix,
							)
						}
					}
				}
			}
		}
	}
}

// ==================== MIG008: Long if/elif chains → match/case candidate ====================

check_match_case :: proc(ctx: ^Migration_Context) {
	walk_stmts_match(ctx, ctx.module.body)
}

walk_stmts_match :: proc(ctx: ^Migration_Context, stmts: []parser.Stmt) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.If_Stmt:
			count := count_elif_chain(s)
			if count >= 3 {
				// Check if they compare the same variable
				var_name := extract_compare_var(s.test)
				if len(var_name) > 0 && all_branches_compare_same(s, var_name) {
					what := fmt.tprintf("if/elif chain with %d branches could use match/case", count)
					fix := fmt.tprintf("Consider refactoring to match %s: / case ...", var_name)
					emit(ctx, "MIG008", s.loc, what,
						"PEP 634 introduced structural pattern matching",
						fix,
					)
				}
			}
			walk_stmts_match(ctx, s.body)
			walk_stmts_match(ctx, s.orelse)
		case ^parser.Func_Def:
			walk_stmts_match(ctx, s.body)
		case ^parser.Async_Func_Def:
			walk_stmts_match(ctx, s.body)
		case ^parser.Class_Def:
			walk_stmts_match(ctx, s.body)
		case ^parser.For_Stmt:
			walk_stmts_match(ctx, s.body)
			walk_stmts_match(ctx, s.orelse)
		case ^parser.While_Stmt:
			walk_stmts_match(ctx, s.body)
			walk_stmts_match(ctx, s.orelse)
		case ^parser.With_Stmt:
			walk_stmts_match(ctx, s.body)
		case ^parser.Try_Stmt:
			walk_stmts_match(ctx, s.body)
			for h in s.handlers { walk_stmts_match(ctx, h.body) }
			walk_stmts_match(ctx, s.orelse)
			walk_stmts_match(ctx, s.finalbody)
		}
	}
}

count_elif_chain :: proc(if_stmt: ^parser.If_Stmt) -> int {
	count := 1 // the initial if
	orelse := if_stmt.orelse
	for len(orelse) == 1 {
		elif_stmt, ok := orelse[0].(^parser.If_Stmt)
		if !ok { break }
		count += 1
		orelse = elif_stmt.orelse
	}
	return count
}

extract_compare_var :: proc(test: parser.Expr) -> string {
	cmp, ok := test.(^parser.Compare_Expr)
	if !ok { return "" }
	if len(cmp.ops) != 1 { return "" }
	if cmp.ops[0] != .Eq { return "" }
	name, is_name := cmp.left.(^parser.Name_Expr)
	if !is_name { return "" }
	return name.id
}

all_branches_compare_same :: proc(if_stmt: ^parser.If_Stmt, var_name: string) -> bool {
	orelse := if_stmt.orelse
	for len(orelse) == 1 {
		elif_stmt, ok := orelse[0].(^parser.If_Stmt)
		if !ok { break }
		branch_var := extract_compare_var(elif_stmt.test)
		if branch_var != var_name { return false }
		orelse = elif_stmt.orelse
	}
	return true
}

// ==================== Annotation Walker ====================

// Walks all annotations in the module, calling the checker for each annotation expression.
walk_annotations :: proc(ctx: ^Migration_Context, stmts: []parser.Stmt, code: string,
	checker: proc(ctx: ^Migration_Context, code: string, expr: parser.Expr)) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Ann_Assign:
			walk_annotation_expr(ctx, code, s.annotation, checker)
		case ^parser.Func_Def:
			// Return annotation
			if s.returns != nil { walk_annotation_expr(ctx, code, s.returns, checker) }
			// Parameter annotations
			walk_arg_annotations(ctx, code, &s.args, checker)
			walk_annotations(ctx, s.body, code, checker)
		case ^parser.Async_Func_Def:
			if s.returns != nil { walk_annotation_expr(ctx, code, s.returns, checker) }
			walk_arg_annotations(ctx, code, &s.args, checker)
			walk_annotations(ctx, s.body, code, checker)
		case ^parser.Class_Def:
			walk_annotations(ctx, s.body, code, checker)
		case ^parser.If_Stmt:
			walk_annotations(ctx, s.body, code, checker)
			walk_annotations(ctx, s.orelse, code, checker)
		case ^parser.For_Stmt:
			walk_annotations(ctx, s.body, code, checker)
			walk_annotations(ctx, s.orelse, code, checker)
		case ^parser.While_Stmt:
			walk_annotations(ctx, s.body, code, checker)
			walk_annotations(ctx, s.orelse, code, checker)
		case ^parser.With_Stmt:
			walk_annotations(ctx, s.body, code, checker)
		case ^parser.Try_Stmt:
			walk_annotations(ctx, s.body, code, checker)
			for h in s.handlers { walk_annotations(ctx, h.body, code, checker) }
			walk_annotations(ctx, s.orelse, code, checker)
			walk_annotations(ctx, s.finalbody, code, checker)
		}
	}
}

walk_arg_annotations :: proc(ctx: ^Migration_Context, code: string, args: ^parser.Arguments,
	checker: proc(ctx: ^Migration_Context, code: string, expr: parser.Expr)) {
	for arg in args.posonlyargs { if arg.annotation != nil { walk_annotation_expr(ctx, code, arg.annotation, checker) } }
	for arg in args.args { if arg.annotation != nil { walk_annotation_expr(ctx, code, arg.annotation, checker) } }
	if args.vararg != nil && args.vararg.annotation != nil { walk_annotation_expr(ctx, code, args.vararg.annotation, checker) }
	for arg in args.kwonlyargs { if arg.annotation != nil { walk_annotation_expr(ctx, code, arg.annotation, checker) } }
	if args.kwarg != nil && args.kwarg.annotation != nil { walk_annotation_expr(ctx, code, args.kwarg.annotation, checker) }
}

// Walk an annotation expression recursively — check at each level, then descend into subscript args.
walk_annotation_expr :: proc(ctx: ^Migration_Context, code: string, expr: parser.Expr,
	checker: proc(ctx: ^Migration_Context, code: string, expr: parser.Expr)) {
	if expr == nil { return }
	// Check this expression
	checker(ctx, code, expr)
	// Descend into subscript slices (Union[X, Y] → check X and Y too)
	#partial switch e in expr {
	case ^parser.Subscript_Expr:
		walk_annotation_expr(ctx, code, e.slice, checker)
	case ^parser.Tuple_Expr:
		for elt in e.elts { walk_annotation_expr(ctx, code, elt, checker) }
	case ^parser.Bin_Op_Expr:
		// X | Y syntax — walk both sides
		walk_annotation_expr(ctx, code, e.left, checker)
		walk_annotation_expr(ctx, code, e.right, checker)
	}
}

// ==================== Expression Walker ====================

walk_exprs :: proc(ctx: ^Migration_Context, stmts: []parser.Stmt,
	checker: proc(ctx: ^Migration_Context, expr: parser.Expr)) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Expr_Stmt:
			walk_expr_tree(ctx, s.value, checker)
		case ^parser.Assign:
			walk_expr_tree(ctx, s.value, checker)
			for t in s.targets { walk_expr_tree(ctx, t, checker) }
		case ^parser.Return_Stmt:
			if s.value != nil { walk_expr_tree(ctx, s.value, checker) }
		case ^parser.Func_Def:
			walk_exprs(ctx, s.body, checker)
		case ^parser.Async_Func_Def:
			walk_exprs(ctx, s.body, checker)
		case ^parser.Class_Def:
			walk_exprs(ctx, s.body, checker)
		case ^parser.If_Stmt:
			walk_expr_tree(ctx, s.test, checker)
			walk_exprs(ctx, s.body, checker)
			walk_exprs(ctx, s.orelse, checker)
		case ^parser.For_Stmt:
			walk_expr_tree(ctx, s.iter, checker)
			walk_exprs(ctx, s.body, checker)
			walk_exprs(ctx, s.orelse, checker)
		case ^parser.While_Stmt:
			walk_expr_tree(ctx, s.test, checker)
			walk_exprs(ctx, s.body, checker)
			walk_exprs(ctx, s.orelse, checker)
		case ^parser.With_Stmt:
			walk_exprs(ctx, s.body, checker)
		case ^parser.Try_Stmt:
			walk_exprs(ctx, s.body, checker)
			for h in s.handlers { walk_exprs(ctx, h.body, checker) }
			walk_exprs(ctx, s.orelse, checker)
			walk_exprs(ctx, s.finalbody, checker)
		}
	}
}

walk_expr_tree :: proc(ctx: ^Migration_Context, expr: parser.Expr,
	checker: proc(ctx: ^Migration_Context, expr: parser.Expr)) {
	if expr == nil { return }
	checker(ctx, expr)
	#partial switch e in expr {
	case ^parser.Call_Expr:
		walk_expr_tree(ctx, e.func, checker)
		for arg in e.args { walk_expr_tree(ctx, arg, checker) }
		for kw in e.keywords { walk_expr_tree(ctx, kw.value, checker) }
	case ^parser.Attribute_Expr:
		walk_expr_tree(ctx, e.value, checker)
	case ^parser.Subscript_Expr:
		walk_expr_tree(ctx, e.value, checker)
		walk_expr_tree(ctx, e.slice, checker)
	case ^parser.Bool_Op_Expr:
		for v in e.values { walk_expr_tree(ctx, v, checker) }
	case ^parser.Bin_Op_Expr:
		walk_expr_tree(ctx, e.left, checker)
		walk_expr_tree(ctx, e.right, checker)
	case ^parser.Unary_Op_Expr:
		walk_expr_tree(ctx, e.operand, checker)
	case ^parser.Compare_Expr:
		walk_expr_tree(ctx, e.left, checker)
		for c in e.comparators { walk_expr_tree(ctx, c, checker) }
	case ^parser.If_Expr:
		walk_expr_tree(ctx, e.test, checker)
		walk_expr_tree(ctx, e.body, checker)
		walk_expr_tree(ctx, e.orelse, checker)
	case ^parser.Tuple_Expr:
		for elt in e.elts { walk_expr_tree(ctx, elt, checker) }
	case ^parser.List_Expr:
		for elt in e.elts { walk_expr_tree(ctx, elt, checker) }
	case ^parser.Dict_Expr:
		for k in e.keys { walk_expr_tree(ctx, k, checker) }
		for v in e.values { walk_expr_tree(ctx, v, checker) }
	case ^parser.Set_Expr:
		for elt in e.elts { walk_expr_tree(ctx, elt, checker) }
	}
}

// ==================== Diagnostic Emission ====================

emit :: proc(ctx: ^Migration_Context, code: string, loc: parser.Src_Loc,
	what, why, fix: string) {
	append(&ctx.diagnostics, core.Diagnostic{
		severity = .Suggestion,
		location = core.Location{
			file   = ctx.file_path,
			line   = int(loc.line),
			column = int(loc.col),
		},
		what = what,
		why  = why,
		fix  = fix,
		code = code,
	})
}
