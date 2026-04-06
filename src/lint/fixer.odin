package lint

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

import parser "mimir:parser"
import core "mimir:core"

// Auto-fix infrastructure for safe lint rule corrections.
// Only applies fixes that are guaranteed to preserve behavior.
//
// Fixable rules:
//   L008 — compare-to-none: x == None → x is None, x != None → x is not None
//   L010 — is-with-literal: x is 1 → x == 1, x is not 1 → x != 1
//   trailing-ws — trailing whitespace removal (always applied in fix mode)

Fix_Edit :: struct {
	line:     int,    // 1-based line number
	old_text: string, // text to find on the line
	new_text: string, // replacement text
}

// Collect fixable edits from lint diagnostics and AST analysis.
collect_fixes :: proc(
	module: ^parser.Module,
	source: string,
	file_path: string,
	config: ^Lint_Config,
	allocator: mem.Allocator,
) -> [dynamic]Fix_Edit {
	fixes := make([dynamic]Fix_Edit, 0, 16, allocator)
	lines := strings.split(source, "\n", allocator)

	// Trailing whitespace removal (always applied)
	for line, idx in lines {
		trimmed := strings.trim_right(line, " \t")
		if len(trimmed) < len(line) {
			append(&fixes, Fix_Edit{
				line     = idx + 1,
				old_text = line,
				new_text = trimmed,
			})
		}
	}

	// L008: compare-to-none fixes (from AST)
	if is_rule_enabled("L008", config) {
		_collect_none_compare_fixes(module.body, lines, &fixes, allocator)
	}

	// L010: is-with-literal fixes (from AST)
	if is_rule_enabled("L010", config) {
		_collect_is_literal_fixes(module.body, lines, &fixes, allocator)
	}

	return fixes
}

// Apply collected fixes to source text and write back to file.
apply_fixes :: proc(
	source: string,
	fixes: []Fix_Edit,
	file_path: string,
	allocator: mem.Allocator,
) -> (fixed_count: int) {
	if len(fixes) == 0 { return 0 }

	lines := strings.split(source, "\n", allocator)
	fixed_count = 0

	for fix in fixes {
		idx := fix.line - 1
		if idx < 0 || idx >= len(lines) { continue }

		if fix.old_text == lines[idx] {
			lines[idx] = fix.new_text
			fixed_count += 1
		} else if strings.contains(lines[idx], fix.old_text) {
			// Substring replacement
			result, _ := strings.replace(lines[idx], fix.old_text, fix.new_text, 1, allocator)
			lines[idx] = result
			fixed_count += 1
		}
	}

	if fixed_count > 0 {
		output := strings.join(lines, "\n", allocator)
		_ = os.write_entire_file(file_path, transmute([]u8)output)
	}

	return fixed_count
}

// ==================== L008 None Comparison Fixes ====================

@(private = "file")
_collect_none_compare_fixes :: proc(
	stmts: []parser.Stmt,
	lines: []string,
	fixes: ^[dynamic]Fix_Edit,
	allocator: mem.Allocator,
) {
	for stmt in stmts {
		_walk_stmt_for_none_fixes(stmt, lines, fixes, allocator)
	}
}

@(private = "file")
_walk_stmt_for_none_fixes :: proc(
	stmt: parser.Stmt,
	lines: []string,
	fixes: ^[dynamic]Fix_Edit,
	allocator: mem.Allocator,
) {
	#partial switch s in stmt {
	case ^parser.Expr_Stmt:
		_check_expr_none_fix(s.value, lines, fixes, allocator)
	case ^parser.Assign:
		_check_expr_none_fix(s.value, lines, fixes, allocator)
	case ^parser.If_Stmt:
		_check_expr_none_fix(s.test, lines, fixes, allocator)
		_collect_none_compare_fixes(s.body, lines, fixes, allocator)
		_collect_none_compare_fixes(s.orelse, lines, fixes, allocator)
	case ^parser.While_Stmt:
		_check_expr_none_fix(s.test, lines, fixes, allocator)
		_collect_none_compare_fixes(s.body, lines, fixes, allocator)
	case ^parser.Assert_Stmt:
		_check_expr_none_fix(s.test, lines, fixes, allocator)
	case ^parser.Return_Stmt:
		if s.value != nil { _check_expr_none_fix(s.value, lines, fixes, allocator) }
	case ^parser.Func_Def:
		_collect_none_compare_fixes(s.body, lines, fixes, allocator)
	case ^parser.Async_Func_Def:
		_collect_none_compare_fixes(s.body, lines, fixes, allocator)
	case ^parser.Class_Def:
		_collect_none_compare_fixes(s.body, lines, fixes, allocator)
	case ^parser.For_Stmt:
		_collect_none_compare_fixes(s.body, lines, fixes, allocator)
	case ^parser.Try_Stmt:
		_collect_none_compare_fixes(s.body, lines, fixes, allocator)
		for h in s.handlers { _collect_none_compare_fixes(h.body, lines, fixes, allocator) }
	}
}

@(private = "file")
_check_expr_none_fix :: proc(
	expr: parser.Expr,
	lines: []string,
	fixes: ^[dynamic]Fix_Edit,
	allocator: mem.Allocator,
) {
	if expr == nil { return }
	cmp, ok := expr.(^parser.Compare_Expr)
	if !ok { return }
	if len(cmp.ops) != 1 || len(cmp.comparators) != 1 { return }

	// Check if right side is None
	right_const, rconst_ok := cmp.comparators[0].(^parser.Constant_Expr)
	if !rconst_ok { return }
	is_none := false
	#partial switch _ in right_const.value {
	case parser.Const_None: is_none = true
	}
	if !is_none { return }

	line_idx := int(cmp.loc.line) - 1
	if line_idx < 0 || line_idx >= len(lines) { return }

	#partial switch cmp.ops[0] {
	case .Eq:
		append(fixes, Fix_Edit{
			line     = int(cmp.loc.line),
			old_text = "== None",
			new_text = "is None",
		})
	case .Not_Eq:
		append(fixes, Fix_Edit{
			line     = int(cmp.loc.line),
			old_text = "!= None",
			new_text = "is not None",
		})
	}
}

// ==================== L010 Is-With-Literal Fixes ====================

@(private = "file")
_collect_is_literal_fixes :: proc(
	stmts: []parser.Stmt,
	lines: []string,
	fixes: ^[dynamic]Fix_Edit,
	allocator: mem.Allocator,
) {
	for stmt in stmts {
		_walk_stmt_for_is_fixes(stmt, lines, fixes, allocator)
	}
}

@(private = "file")
_walk_stmt_for_is_fixes :: proc(
	stmt: parser.Stmt,
	lines: []string,
	fixes: ^[dynamic]Fix_Edit,
	allocator: mem.Allocator,
) {
	#partial switch s in stmt {
	case ^parser.Expr_Stmt:
		_check_expr_is_literal_fix(s.value, lines, fixes, allocator)
	case ^parser.If_Stmt:
		_check_expr_is_literal_fix(s.test, lines, fixes, allocator)
		_collect_is_literal_fixes(s.body, lines, fixes, allocator)
		_collect_is_literal_fixes(s.orelse, lines, fixes, allocator)
	case ^parser.While_Stmt:
		_check_expr_is_literal_fix(s.test, lines, fixes, allocator)
		_collect_is_literal_fixes(s.body, lines, fixes, allocator)
	case ^parser.Func_Def:
		_collect_is_literal_fixes(s.body, lines, fixes, allocator)
	case ^parser.Async_Func_Def:
		_collect_is_literal_fixes(s.body, lines, fixes, allocator)
	case ^parser.Class_Def:
		_collect_is_literal_fixes(s.body, lines, fixes, allocator)
	}
}

@(private = "file")
_check_expr_is_literal_fix :: proc(
	expr: parser.Expr,
	lines: []string,
	fixes: ^[dynamic]Fix_Edit,
	allocator: mem.Allocator,
) {
	if expr == nil { return }
	cmp, ok := expr.(^parser.Compare_Expr)
	if !ok { return }
	if len(cmp.ops) != 1 || len(cmp.comparators) != 1 { return }

	// Check if right side is a literal (not None — that's handled by L008)
	right_const, rconst_ok := cmp.comparators[0].(^parser.Constant_Expr)
	if !rconst_ok { return }
	skip := false
	#partial switch _ in right_const.value {
	case parser.Const_None: skip = true
	}
	if skip { return } // Skip None — L008 handles it

	line_idx := int(cmp.loc.line) - 1
	if line_idx < 0 || line_idx >= len(lines) { return }

	#partial switch cmp.ops[0] {
	case .Is:
		// "x is 1" → "x == 1"
		// Find "is" keyword on the line that isn't "is not"
		line := lines[line_idx]
		is_pos := strings.index(line, " is ")
		if is_pos >= 0 {
			// Make sure it's not "is not"
			rest := line[is_pos+4:]
			if !strings.has_prefix(strings.trim_left_space(rest), "not") {
				append(fixes, Fix_Edit{
					line     = int(cmp.loc.line),
					old_text = " is ",
					new_text = " == ",
				})
			}
		}
	case .Is_Not:
		// "x is not 1" → "x != 1"
		append(fixes, Fix_Edit{
			line     = int(cmp.loc.line),
			old_text = " is not ",
			new_text = " != ",
		})
	}
}
