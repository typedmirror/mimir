package platform

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

import parser "mimir:parser"
import binder "mimir:binder"
import flow   "mimir:flow"
import checker "mimir:checker"
import core   "mimir:core"

// ==================== Codemod Infrastructure ====================
//
// Type-aware source transformations. Runs the full analysis pipeline
// (parse → bind → flow → check) then applies source-level edits
// guided by type information.

Codemod_Kind :: enum {
	Add_Return_Types,
	Remove_Unused_Imports,
	Modernize_Annotations,
}

Codemod_Edit :: struct {
	line:    int,       // 1-indexed line number
	col:     int,       // 0-indexed column
	old_text: string,   // text to replace (empty = insert)
	new_text: string,   // replacement text
}

Codemod_Result :: struct {
	edits:     [dynamic]Codemod_Edit,
	file_path: string,
}

// ==================== Entry Point ====================

run_codemod :: proc(
	kind: Codemod_Kind,
	file: string,
	allocator: mem.Allocator,
	dry_run: bool = true,
) -> (int, bool) {
	// Parse
	module, parse_err := parser.parse_native(file, allocator)
	if parse_err != nil {
		#partial switch e in parse_err {
		case parser.Syntax_Error:
			fmt.eprintfln("%s:%d:%d: error: %s", e.file, e.line, e.col, e.msg)
		case parser.Bridge_Error:
			fmt.eprintfln("mimir codemod: %s: %s", file, e.msg)
		}
		return 0, false
	}

	// Bind
	bind_result := binder.bind(module, file, allocator)

	// Flow
	flow_result := flow.analyze(module, &bind_result, file, allocator)

	// Check (single-file mode)
	check_result := checker.check(module, &bind_result, &flow_result, file, allocator)

	// Read source
	data, read_err := os.read_entire_file(file, allocator)
	if read_err != nil {
		fmt.eprintfln("mimir codemod: cannot read '%s'", file)
		return 0, false
	}
	source := string(data)
	lines := strings.split(source, "\n")

	// Collect edits
	result := Codemod_Result{
		edits     = make([dynamic]Codemod_Edit, 0, 16, allocator),
		file_path = file,
	}

	switch kind {
	case .Add_Return_Types:
		collect_return_type_edits(module, &bind_result, &check_result, lines, &result, allocator)
	case .Remove_Unused_Imports:
		collect_unused_import_edits(module, &bind_result, &flow_result, lines, &result, allocator)
	case .Modernize_Annotations:
		collect_modernize_edits(module, lines, &result, allocator)
	}

	if len(result.edits) == 0 {
		return 0, true
	}

	if dry_run {
		// Print what would change
		for &edit in result.edits {
			if edit.old_text == "\n" {
				fmt.printfln("%s:%d: remove line", file, edit.line)
			} else if len(edit.old_text) == 0 {
				fmt.printfln("%s:%d:%d: insert '%s'", file, edit.line, edit.col, edit.new_text)
			} else {
				fmt.printfln("%s:%d:%d: replace '%s' with '%s'", file, edit.line, edit.col, edit.old_text, edit.new_text)
			}
		}
		return len(result.edits), true
	}

	// Apply edits (bottom-up to preserve line numbers)
	new_lines := make([dynamic]string, len(lines), allocator)
	for l, i in lines { new_lines[i] = l }

	// Sort edits by line descending so later edits don't shift earlier ones
	_sort_edits_desc(&result.edits)

	for &edit in result.edits {
		idx := edit.line - 1
		if idx < 0 || idx >= len(new_lines) { continue }

		if edit.old_text == "\n" {
			// Delete entire line
			ordered_remove(&new_lines, idx)
		} else if edit.col >= 0 && edit.col <= len(new_lines[idx]) {
			// Positional edit: insert new_text at col, replacing old_text length
			line := new_lines[idx]
			before := line[:edit.col]
			skip := len(edit.old_text)
			after := line[edit.col + skip:] if edit.col + skip <= len(line) else ""
			new_lines[idx] = strings.concatenate({before, edit.new_text, after}, allocator)
		}
	}

	// Write back
	output := strings.join(new_lines[:], "\n", allocator)
	_ = os.write_entire_file(file, transmute([]u8)output)

	return len(result.edits), true
}

// ==================== Add Return Types ====================
//
// For functions without return type annotations, inserts the inferred type.
// Uses check_result.inferred_returns which maps scope_id → Type_ID.

collect_return_type_edits :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	check_result: ^checker.Check_Result,
	lines: []string,
	result: ^Codemod_Result,
	allocator: mem.Allocator,
) {
	_scan_funcs_for_return_edits(module.body, bind_result, check_result, lines, result, allocator)
}

_scan_funcs_for_return_edits :: proc(
	stmts: []parser.Stmt,
	bind_result: ^binder.Bind_Result,
	check_result: ^checker.Check_Result,
	lines: []string,
	result: ^Codemod_Result,
	allocator: mem.Allocator,
) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			if s.returns == nil {
				// Find scope for this function
				scope_id := _find_func_scope(bind_result, s.name, s.loc)
				if scope_id != binder.INVALID_SCOPE {
					if ret_type, ok := check_result.inferred_returns[scope_id]; ok {
						if ret_type != checker.TYPE_UNKNOWN && ret_type != checker.TYPE_ANY {
							type_str := checker.type_to_string(&check_result.registry, ret_type)
							// Find the colon at end of def line
							line_idx := int(s.loc.line) - 1
							if line_idx >= 0 && line_idx < len(lines) {
								line := lines[line_idx]
								// Find ): pattern — insert before :
								colon_pos := _find_def_colon(line)
								if colon_pos >= 0 {
									append(&result.edits, Codemod_Edit{
										line     = int(s.loc.line),
										col      = colon_pos,
										old_text = ":",
										new_text = fmt.aprintf(" -> %s:", type_str, allocator = allocator),
									})
								}
							}
						}
					}
				}
			}
			// Recurse into body for nested functions
			_scan_funcs_for_return_edits(s.body, bind_result, check_result, lines, result, allocator)

		case ^parser.Async_Func_Def:
			if s.returns == nil {
				scope_id := _find_func_scope(bind_result, s.name, s.loc)
				if scope_id != binder.INVALID_SCOPE {
					if ret_type, ok := check_result.inferred_returns[scope_id]; ok {
						if ret_type != checker.TYPE_UNKNOWN && ret_type != checker.TYPE_ANY {
							type_str := checker.type_to_string(&check_result.registry, ret_type)
							line_idx := int(s.loc.line) - 1
							if line_idx >= 0 && line_idx < len(lines) {
								line := lines[line_idx]
								colon_pos := _find_def_colon(line)
								if colon_pos >= 0 {
									append(&result.edits, Codemod_Edit{
										line     = int(s.loc.line),
										col      = colon_pos,
										old_text = ":",
										new_text = fmt.aprintf(" -> %s:", type_str, allocator = allocator),
									})
								}
							}
						}
					}
				}
			}
			_scan_funcs_for_return_edits(s.body, bind_result, check_result, lines, result, allocator)

		case ^parser.Class_Def:
			_scan_funcs_for_return_edits(s.body, bind_result, check_result, lines, result, allocator)
		case ^parser.If_Stmt:
			_scan_funcs_for_return_edits(s.body, bind_result, check_result, lines, result, allocator)
			_scan_funcs_for_return_edits(s.orelse, bind_result, check_result, lines, result, allocator)
		case ^parser.For_Stmt:
			_scan_funcs_for_return_edits(s.body, bind_result, check_result, lines, result, allocator)
		case ^parser.While_Stmt:
			_scan_funcs_for_return_edits(s.body, bind_result, check_result, lines, result, allocator)
		case ^parser.Try_Stmt:
			_scan_funcs_for_return_edits(s.body, bind_result, check_result, lines, result, allocator)
			for h in s.handlers { _scan_funcs_for_return_edits(h.body, bind_result, check_result, lines, result, allocator) }
			_scan_funcs_for_return_edits(s.orelse, bind_result, check_result, lines, result, allocator)
			_scan_funcs_for_return_edits(s.finalbody, bind_result, check_result, lines, result, allocator)
		case ^parser.With_Stmt:
			_scan_funcs_for_return_edits(s.body, bind_result, check_result, lines, result, allocator)
		}
	}
}

// ==================== Remove Unused Imports ====================
//
// Identifies imports where no imported name is referenced in the binder's refs map.

collect_unused_import_edits :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	flow_result: ^flow.Flow_Result,
	lines: []string,
	result: ^Codemod_Result,
	allocator: mem.Allocator,
) {
	// Build set of all Symbol_IDs that have at least one Load reference
	used_syms := make(map[binder.Symbol_ID]bool, 64, allocator)
	for _, sym_id in bind_result.refs {
		used_syms[sym_id] = true
	}

	// Also check DFG — symbols with definitions but no uses are still "defined"
	// We want symbols that are imported but never used as a Load reference
	for &imp in bind_result.imports {
		if imp.is_star { continue } // can't remove star imports

		// from X import a, b, c — check each name
		if len(imp.names) > 0 {
			all_unused := true
			for name in imp.names {
				local_name := name.alias if len(name.alias) > 0 else name.name
				sym_id := _find_import_sym(bind_result, local_name, imp.loc)
				if sym_id != binder.INVALID_SYMBOL && sym_id in used_syms {
					all_unused = false
					break
				}
			}
			if all_unused && imp.loc.line > 0 {
				append(&result.edits, Codemod_Edit{
					line     = int(imp.loc.line),
					col      = 0,
					old_text = "\n", // sentinel: delete line
					new_text = "",
				})
			}
		} else {
			// import X — check if X is used
			// Find the symbol for the module name
			local := imp.module_name
			// For "import os.path", local is "os"
			dot_idx := strings.index_byte(local, '.')
			if dot_idx >= 0 { local = local[:dot_idx] }

			sym_id := _find_import_sym(bind_result, local, imp.loc)
			if sym_id != binder.INVALID_SYMBOL && sym_id not_in used_syms {
				if imp.loc.line > 0 {
					append(&result.edits, Codemod_Edit{
						line     = int(imp.loc.line),
						col      = 0,
						old_text = "\n",
						new_text = "",
					})
				}
			}
		}
	}
}

// ==================== Modernize Annotations (PEP 585 + PEP 604) ====================
//
// Converts old-style typing imports to modern builtins:
//   List[int]         → list[int]
//   Dict[str, int]    → dict[str, int]
//   Set[str]          → set[str]
//   Tuple[int, str]   → tuple[int, str]
//   FrozenSet[int]    → frozenset[int]
//   Optional[X]       → X | None
//   Union[X, Y]       → X | Y
//
// Text-based — scans lines for patterns. No AST needed (annotations are syntactically simple).

MODERNIZE_SIMPLE :: [?][2]string{
	{"List[",      "list["},
	{"Dict[",      "dict["},
	{"Set[",       "set["},
	{"Tuple[",     "tuple["},
	{"FrozenSet[", "frozenset["},
	{"Sequence[",  "collections.abc.Sequence["},
}

collect_modernize_edits :: proc(
	module: ^parser.Module,
	lines: []string,
	result: ^Codemod_Result,
	allocator: mem.Allocator,
) {
	for line, line_idx in lines {
		// Simple replacements: List[ → list[, etc. Find ALL occurrences per line.
		for mapping in MODERNIZE_SIMPLE {
			old := mapping[0]
			new := mapping[1]
			search_from := 0
			for {
				pos := _find_annotation_token_from(line, old, search_from)
				if pos < 0 { break }
				append(&result.edits, Codemod_Edit{
					line     = line_idx + 1,
					col      = pos,
					old_text = old,
					new_text = new,
				})
				search_from = pos + len(old) // skip past this match
			}
		}

		// Optional[X] → X | None (find ALL occurrences)
		{
			search_from := 0
			for {
				opt_pos := _find_annotation_token_from(line, "Optional[", search_from)
				if opt_pos < 0 { break }
				inner_start := opt_pos + len("Optional[")
				close := _find_matching_bracket(line, inner_start - 1)
				if close > inner_start {
					inner := line[inner_start:close]
					append(&result.edits, Codemod_Edit{
						line     = line_idx + 1,
						col      = opt_pos,
						old_text = line[opt_pos:close + 1],
						new_text = fmt.aprintf("%s | None", inner, allocator = allocator),
					})
					search_from = close + 1
				} else {
					break
				}
			}
		}

		// Union[X, Y] → X | Y (find ALL occurrences)
		{
			search_from := 0
			for {
				union_pos := _find_annotation_token_from(line, "Union[", search_from)
				if union_pos < 0 { break }
				inner_start := union_pos + len("Union[")
				close := _find_matching_bracket(line, inner_start - 1)
				if close > inner_start {
					inner := line[inner_start:close]
					replaced, _ := strings.replace_all(inner, ", ", " | ", allocator)
					append(&result.edits, Codemod_Edit{
						line     = line_idx + 1,
						col      = union_pos,
						old_text = line[union_pos:close + 1],
						new_text = replaced,
					})
					search_from = close + 1
				} else {
					break
				}
			}
		}
	}
}

// Find a typing annotation token in a line, skipping strings and comments.
_find_annotation_token :: proc(line: string, token: string) -> int {
	return _find_annotation_token_from(line, token, 0)
}

// Find a typing annotation token starting from a given position.
_find_annotation_token_from :: proc(line: string, token: string, start: int) -> int {
	if len(token) > len(line) { return -1 }
	in_str := false
	str_ch: u8 = 0
	for i := 0; i <= len(line) - len(token); i += 1 {
		c := line[i]
		if in_str {
			if c == str_ch { in_str = false }
			continue
		}
		if c == '\'' || c == '"' { in_str = true; str_ch = c; continue }
		if c == '#' { return -1 } // rest is comment
		if i < start { continue } // skip to start position
		if line[i:i + len(token)] == token {
			if i > 0 {
				prev := line[i - 1]
				if (prev >= 'a' && prev <= 'z') || (prev >= 'A' && prev <= 'Z') || prev == '_' {
					continue
				}
			}
			return i
		}
	}
	return -1
}

// Find the matching ] for the [ at position `open_pos`.
_find_matching_bracket :: proc(line: string, open_pos: int) -> int {
	if open_pos < 0 || open_pos >= len(line) || line[open_pos] != '[' { return -1 }
	depth := 0
	for i := open_pos; i < len(line); i += 1 {
		if line[i] == '[' { depth += 1 }
		if line[i] == ']' { depth -= 1; if depth == 0 { return i } }
	}
	return -1
}

// ==================== Helpers ====================

_find_func_scope :: proc(bind_result: ^binder.Bind_Result, name: string, loc: parser.Src_Loc) -> binder.Scope_ID {
	for &scope in bind_result.scopes {
		if scope.name == name && scope.kind == .Function &&
		   scope.loc.line == loc.line && scope.loc.col == loc.col {
			return scope.id
		}
	}
	return binder.INVALID_SCOPE
}

_find_import_sym :: proc(bind_result: ^binder.Bind_Result, name: string, loc: parser.Src_Loc) -> binder.Symbol_ID {
	mod_scope := binder.result_get_scope(bind_result, bind_result.module_scope)
	if mod_scope == nil { return binder.INVALID_SYMBOL }
	if sym_id, ok := mod_scope.symbols[name]; ok {
		return sym_id
	}
	return binder.INVALID_SYMBOL
}

// Find the ): colon at end of a def line.
// Handles: `def foo():`, `def foo(x: int):`, `def foo(x, y):`, multiline defs.
_find_def_colon :: proc(line: string) -> int {
	// Walk backwards from end to find the last `:` that's the def body colon
	// Skip trailing whitespace and comments
	i := len(line) - 1
	for i >= 0 && (line[i] == ' ' || line[i] == '\t' || line[i] == '\r') {
		i -= 1
	}
	// Check for comment — find # and use position before it
	comment_pos := -1
	in_str := false
	str_ch: u8 = 0
	for j := 0; j < len(line); j += 1 {
		if in_str {
			if line[j] == str_ch { in_str = false }
			continue
		}
		if line[j] == '\'' || line[j] == '"' { in_str = true; str_ch = line[j]; continue }
		if line[j] == '#' { comment_pos = j; break }
	}
	end := i
	if comment_pos >= 0 && comment_pos < end {
		end = comment_pos - 1
		for end >= 0 && (line[end] == ' ' || line[end] == '\t') { end -= 1 }
	}

	if end >= 0 && line[end] == ':' {
		return end
	}
	return -1
}

// Sort edits by (line DESC, col DESC) so bottom-up + right-to-left application
// preserves both line numbers and column positions on same-line edits.
_sort_edits_desc :: proc(edits: ^[dynamic]Codemod_Edit) {
	for i := 1; i < len(edits); i += 1 {
		key := edits[i]
		j := i - 1
		for j >= 0 && (edits[j].line < key.line || (edits[j].line == key.line && edits[j].col < key.col)) {
			edits[j + 1] = edits[j]
			j -= 1
		}
		edits[j + 1] = key
	}
}
