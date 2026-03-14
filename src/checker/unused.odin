package checker

import "core:fmt"
import "core:mem"
import "core:strings"

import parser "mimir:parser"
import binder "mimir:binder"
import flow   "mimir:flow"
import core   "mimir:core"

// ==================== D001: Unused Variable Detection ====================
//
// Scans DFG definition points against binder refs to find variables that
// are defined but never loaded. More precise than L002 (binder-only) because
// it uses flow-analyzed definition points rather than symbol flags.

detect_unused_variables :: proc(
	flow_result: ^flow.Flow_Result,
	bind_result: ^binder.Bind_Result,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	// Build set of all symbols that have at least one Load reference
	used_syms := collect_used_symbols(bind_result, allocator)

	// Check each scope's DFG defs
	for scope_id, dfg in flow_result.dfgs {
		scope := binder.result_get_scope(bind_result, scope_id)
		if scope == nil { continue }

		// Skip class scopes — attributes may be accessed externally
		if scope.kind == .Class { continue }

		for &def in dfg.defs {
			// Skip parameter defs (stmt_idx == -1)
			if def.stmt_idx < 0 { continue }

			sym := binder.result_get_symbol(bind_result, def.symbol_id)
			if sym == nil { continue }

			if is_excluded_from_unused(sym) { continue }

			// Check if this symbol has any Load reference anywhere
			if def.symbol_id in used_syms { continue }

			append(diagnostics, core.Diagnostic{
				severity = .Warning,
				location = core.Location{
					file   = file_path,
					line   = int(def.loc.line),
					column = int(def.loc.col),
				},
				code = "D001",
				what = fmt.aprintf("variable '%s' is assigned but never used", sym.name, allocator = allocator),
				why  = "unused variables indicate dead code or a missing reference",
				fix  = "remove the variable or prefix with '_' to indicate intentional disuse",
			})
		}
	}
}

// Build set of all symbols that have at least one Load reference
collect_used_symbols :: proc(bind_result: ^binder.Bind_Result, allocator: mem.Allocator) -> map[binder.Symbol_ID]bool {
	result := make(map[binder.Symbol_ID]bool, 64, allocator)

	for key, sym_id in bind_result.refs {
		name_expr := cast(^parser.Name_Expr)key
		if name_expr != nil && name_expr.ctx == .Load {
			result[sym_id] = true
		}
	}

	return result
}

// Check if a symbol should be excluded from D001
is_excluded_from_unused :: proc(sym: ^binder.Symbol) -> bool {
	name := sym.name

	// _ prefix — Python convention for intentional disuse
	if len(name) > 0 && name[0] == '_' { return true }

	// __dunder__ names — special names used by framework/runtime
	if len(name) > 4 && strings.has_prefix(name, "__") && strings.has_suffix(name, "__") {
		return true
	}

	// Imported symbols — handled by L001
	if .Is_Imported in sym.flags { return true }

	// Parameters — unused params may be required by interface
	if .Is_Param in sym.flags { return true }

	// Function and class definitions — may be exported/used externally
	if sym.kind == .Function || sym.kind == .Class { return true }

	// self, cls — method parameters (extra safety, already caught by Is_Param)
	if name == "self" || name == "cls" { return true }

	return false
}
