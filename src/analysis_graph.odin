package mimir

// Unified Analysis Graph — aggregates all per-file analysis results into one
// queryable structure. Centralizes diagnostic emission with dedup, # type: ignore
// filtering, and confidence gating. Pass orchestration replaces procedural
// composition in main.odin command handlers.
//
// Spec section 2.2: "The constraint graph is the central data structure.
// Every analysis feature is a query against it."
//
// This is Layer 1 (aggregation) + Layer 2 (orchestration) + Layer 3 (diagnostics).
// Future layers add cross-domain queries and incremental re-analysis.

import "core:mem"
import "core:strings"
import "core:fmt"
import "core:os"

import "core"
import "parser"
import "binder"
import "flow"
import "checker"
import "modules"
import "platform"
import "concurrency"

// ==================== Analysis Graph ====================

Analysis_Graph :: struct {
	// Source
	module:    ^parser.Module,
	source:    string,
	file_path: string,

	// Pass results (filled incrementally by graph_* procs)
	bind_result:  binder.Bind_Result,
	flow_result:  flow.Flow_Result,
	check_result: checker.Check_Result,
	registry:     checker.Type_Registry,
	builtins:     checker.Builtin_Names,
	import_types: map[binder.Symbol_ID]checker.Type_ID,

	// Shared derived data (built by graph_bind)
	import_map:   map[string]string,   // local_name → module_name
	has_import:   map[string]bool,     // module_name → true
	type_ignores: map[i32]bool,        // line → true
	has_whole_file_ignore: bool,

	// Centralized diagnostics
	diagnostics:  [dynamic]core.Diagnostic,
	seen_keys:    map[u64]bool,  // dedup by (line, column, code) hash

	// T1: unresolved-import accounting — drives the end-of-run summary line
	// ("N imports unresolved — type coverage incomplete"). Incremented once per
	// import statement that resolves to nothing (B003).
	unresolved_import_count: int,

	// Pass completion flags
	bound:   bool,
	flowed:  bool,
	checked: bool,

	// Arena
	allocator: mem.Allocator,
}

// Initialize an analysis graph for a single file.
init_analysis_graph :: proc(
	module: ^parser.Module,
	source: string,
	file_path: string,
	allocator: mem.Allocator,
) -> Analysis_Graph {
	g: Analysis_Graph
	g.module = module
	g.source = source
	g.file_path = file_path
	g.allocator = allocator
	g.diagnostics = make([dynamic]core.Diagnostic, 0, 64, allocator)
	g.seen_keys = make(map[u64]bool, 64, allocator)
	g.import_types = make(map[binder.Symbol_ID]checker.Type_ID, 8, allocator)
	return g
}

// ==================== Centralized Diagnostic Emission ====================

// Emit a diagnostic through the centralized pipeline.
// Handles: dedup, # type: ignore (whole-file + per-line), severity filtering.
graph_emit :: proc(g: ^Analysis_Graph, d: core.Diagnostic) {
	// Whole-file ignore suppresses everything
	if g.has_whole_file_ignore { return }

	// Per-line # type: ignore
	if i32(d.location.line) in g.type_ignores { return }

	// Dedup by (line, column, code)
	key: u64 = u64(d.location.line) * 100003 + u64(d.location.column) * 31
	for i := 0; i < len(d.code); i += 1 { key = key * 131 + u64(d.code[i]) }
	if key in g.seen_keys { return }
	g.seen_keys[key] = true

	append(&g.diagnostics, d)
}

// ==================== Pass Orchestration ====================

// Phase 1: Bind — symbol resolution, scope building, import recording.
graph_bind :: proc(g: ^Analysis_Graph) {
	if g.bound { return }

	g.bind_result = binder.bind(g.module, g.file_path, g.allocator)

	// Build type_ignores map
	g.type_ignores = make(map[i32]bool, len(g.module.type_ignores), g.allocator)
	for ti in g.module.type_ignores {
		g.type_ignores[ti.lineno] = true
	}
	g.has_whole_file_ignore = 0 in g.type_ignores

	// Build shared import_map and has_import
	g.import_map = make(map[string]string, 16, g.allocator)
	g.has_import = make(map[string]bool, 16, g.allocator)
	for &imp in g.bind_result.imports {
		if len(imp.module_name) > 0 {
			g.has_import[imp.module_name] = true
		}
		if len(imp.names) > 0 {
			for name in imp.names {
				local := name.alias if len(name.alias) > 0 else name.name
				g.import_map[local] = imp.module_name
			}
		} else {
			local := imp.module_name
			for i := 0; i < len(local); i += 1 {
				if local[i] == '.' { local = local[:i]; break }
			}
			if len(imp.local_name) > 0 {
				local = imp.local_name
			}
			g.import_map[local] = imp.module_name
		}
	}

	// Emit binder diagnostics
	for d in g.bind_result.diagnostics {
		graph_emit(g, d)
	}

	// Emit parse-level diagnostics (P001) — statements the parser dropped
	// during recovery must be visible, never silent.
	for pd in g.module.parse_diagnostics {
		graph_emit(g, core.Diagnostic{
			severity = .Warning,
			location = core.Location{
				file   = g.file_path,
				line   = int(pd.loc.line),
				column = int(pd.loc.col),
			},
			what = pd.what,
			why  = pd.why,
			fix  = pd.fix,
			code = "P001",
		})
	}

	g.bound = true
}

// ==================== Unresolved Import Diagnostics (B003) ====================

// Build the B003 warning for an import that resolved to nothing.
// Shared by the single-file graph path and the multi-file check path.
make_unresolved_import_diag :: proc(
	imp: binder.Import_Record,
	file_path: string,
	allocator: mem.Allocator,
) -> core.Diagnostic {
	// Reconstruct the display name: level dots + module name ("from ..pkg import x" → "..pkg")
	display := imp.module_name
	if imp.level > 0 {
		dots := make([]u8, imp.level, allocator)
		for i := 0; i < imp.level; i += 1 { dots[i] = '.' }
		display = strings.concatenate({string(dots), imp.module_name}, allocator)
	}

	why_text := "the module was not found in same-directory siblings, stdlib stubs, the package cache, or site-packages — its symbols are typed Unknown, so checks touching them are weakened (type coverage incomplete)"
	fix_text := ""
	if imp.level > 0 {
		why_text = "package-relative imports cannot resolve in single-file mode — its symbols are typed Unknown, so checks touching them are weakened (type coverage incomplete)"
		fix_text = "run mimir on the package directory (or ensure __init__.py exists) so package mode engages"
	} else {
		top := imp.module_name
		for i := 0; i < len(top); i += 1 {
			if top[i] == '.' { top = top[:i]; break }
		}
		fix_text = fmt.aprintf(
			"run from the project root, add a project marker (pyproject.toml), or cache the package: mimir add %s",
			top, allocator = allocator)
	}

	return core.Diagnostic{
		severity = .Warning,
		location = core.Location{
			file   = file_path,
			line   = int(imp.loc.line),
			column = int(imp.loc.col),
		},
		what = fmt.aprintf("unresolved import '%s'", display, allocator = allocator),
		why  = why_text,
		fix  = fix_text,
		code = "B003",
	}
}

// ==================== Same-Directory Sibling Resolution ====================

// Directory of a file path ("a/b/c.py" → "a/b"; bare name → ".").
@(private = "file")
_dir_of :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' { return path[:i] }
	}
	return "."
}

// Resolve a module name against the checked file's own directory —
// mypy/sys.path[0] parity: the script's directory is on the search path and
// LOCAL FILES SHADOW installed packages. Handles plain modules (models.py/.pyi),
// sibling packages (models/__init__.py[i]), and dotted names (a.b → a/b.py …).
// `self_path` guards against a file resolving itself.
@(private = "file")
_resolve_sibling_module :: proc(
	dir: string,
	module_name: string,
	self_path: string,
	allocator: mem.Allocator,
) -> (file_path: string, found: bool) {
	if len(module_name) == 0 { return "", false }

	// Convert dots to slashes: "a.b" → "a/b"
	buf := make([dynamic]u8, 0, len(module_name), allocator)
	for i := 0; i < len(module_name); i += 1 {
		if module_name[i] == '.' {
			append(&buf, '/')
		} else {
			append(&buf, module_name[i])
		}
	}
	sub := string(buf[:])

	// .pyi shadows .py (PEP 561); file beats package dir
	candidates := [4]string{
		strings.concatenate({dir, "/", sub, ".pyi"}, allocator),
		strings.concatenate({dir, "/", sub, ".py"}, allocator),
		strings.concatenate({dir, "/", sub, "/__init__.pyi"}, allocator),
		strings.concatenate({dir, "/", sub, "/__init__.py"}, allocator),
	}
	for cand in candidates {
		if cand == self_path { continue }
		if os.is_file(cand) { return cand, true }
	}
	return "", false
}

// Phase 2: Flow analysis — CFG, DFG, guards, narrowing.
graph_flow :: proc(g: ^Analysis_Graph) {
	if g.flowed { return }
	if !g.bound { graph_bind(g) }

	g.flow_result = flow.analyze(g.module, &g.bind_result, g.file_path, g.allocator)
	g.flowed = true
}

// Phase 3: Type checking — inference, constraint solving, shape/device validation.
// Also resolves imports from virtual modules, stdlib stubs, and package cache.
// bridge is optional — needed for parsing third-party stubs from package cache.
graph_check :: proc(g: ^Analysis_Graph, bridge: ^parser.Bridge = nil) {
	if g.checked { return }
	if !g.flowed { graph_flow(g) }

	g.registry = checker.init_registry(g.allocator)
	g.builtins = checker.init_builtins(&g.registry)

	// Resolve imports: virtual → same-dir siblings → stdlib → packages → site-packages.
	// Virtual and sibling resolution have no cache dependency; each fallback
	// carries its own prerequisites. Anything still unresolved is reported (B003)
	// and counted — never silent.
	pkg_cache, cache_ok := platform.init_cache(g.allocator)
	vreg := checker.init_virtual_registry(&g.registry)
	virtual := checker.resolve_virtual_imports(&vreg, &g.bind_result, &g.registry)
	for sym_id, type_id in virtual {
		g.import_types[sym_id] = type_id
	}

	mod_scope := binder.result_get_scope(&g.bind_result, g.bind_result.module_scope)
	if mod_scope != nil {
		parsed_pkgs := make(map[string]modules.Module_Exports, 8, g.allocator)
		stubs_dir, stubs_dir_err := platform.stubs_base_dir(g.allocator)
		has_stubs := stubs_dir_err == nil && platform.stubs_available(g.allocator)
		sp_dirs := modules.discover_site_packages(g.allocator)
		file_dir := _dir_of(g.file_path)

		// Shared resolution context — lazy caches inside persist across imports
		res_ctx := modules.init_resolution_context(&g.registry, g.allocator)
		if has_stubs { res_ctx.stubs_dir = stubs_dir }
		if cache_ok == nil { res_ctx.cache = &pkg_cache }
		if bridge != nil { res_ctx.bridge = bridge }
		res_ctx.site_packages_dirs = sp_dirs

		for imp in g.bind_result.imports {
			if checker.is_virtual_module(&vreg, imp.module_name) { continue }
			// typing/typing_extensions: binder typing_names mechanism.
			// __future__: compiler directive, not a runtime module.
			if imp.module_name == "typing" || imp.module_name == "typing_extensions" ||
			   imp.module_name == "__future__" { continue }

			// Package-relative import in single-file mode: no package context
			// exists (files inside real packages auto-promote to multi-file
			// mode in cmd_check). Truly unresolvable here — say so.
			if imp.level > 0 {
				g.unresolved_import_count += 1
				graph_emit(g, make_unresolved_import_diag(imp, g.file_path, g.allocator))
				continue
			}

			if _, already := parsed_pkgs[imp.module_name]; already { continue }

			// 1. Same-directory sibling — mypy/sys.path[0] parity; LOCAL SHADOWS INSTALLED
			if sib_path, sib_found := _resolve_sibling_module(file_dir, imp.module_name, g.file_path, g.allocator); sib_found {
				sib_exp, sib_ok := modules.extract_package_exports(
					sib_path, imp.module_name, bridge, &g.registry, g.allocator, &res_ctx)
				if sib_ok {
					parsed_pkgs[imp.module_name] = sib_exp
				}
			}

			// 2. Stdlib stubs
			if _, has_pkg := parsed_pkgs[imp.module_name]; !has_pkg {
				if has_stubs && platform.is_stdlib_module(imp.module_name) {
					stdlib_exp, stdlib_ok := modules.resolve_from_stdlib_stubs(imp.module_name, &res_ctx)
					if stdlib_ok {
						parsed_pkgs[imp.module_name] = stdlib_exp
					}
				}
			}

			// 3. Package cache + site-packages
			if _, has_pkg := parsed_pkgs[imp.module_name]; !has_pkg {
				pkg_exp, pkg_ok := modules.resolve_from_site_packages(imp.module_name, &res_ctx)
				if pkg_ok {
					parsed_pkgs[imp.module_name] = pkg_exp
				}
			}

			// Wire up resolved exports — or report the failure. Never silent.
			if pkg_exports, has_exp := parsed_pkgs[imp.module_name]; has_exp {
				if len(imp.names) == 0 {
					local_name := imp.module_name
					for j := 0; j < len(local_name); j += 1 {
						if local_name[j] == '.' { local_name = local_name[:j]; break }
					}
					if len(imp.local_name) > 0 { local_name = imp.local_name }
					if sym_id, ok := mod_scope.symbols[local_name]; ok {
						mod_type_id := checker.register_type(&g.registry, checker.Module_Type{
							name    = imp.module_name,
							exports = pkg_exports.types,
						})
						g.import_types[sym_id] = mod_type_id
					}
				} else if !imp.is_star {
					for imp_name in imp.names {
						local := imp_name.alias if len(imp_name.alias) > 0 else imp_name.name
						if sym_id, ok := mod_scope.symbols[local]; ok {
							if type_id, found2 := pkg_exports.types[imp_name.name]; found2 {
								g.import_types[sym_id] = type_id
							}
						}
					}
				}
			} else {
				g.unresolved_import_count += 1
				graph_emit(g, make_unresolved_import_diag(imp, g.file_path, g.allocator))
			}
		}
	}

	g.check_result = checker.check_with_imports(
		g.module, &g.bind_result, &g.flow_result, g.file_path,
		&g.registry, &g.builtins, g.import_types, g.allocator,
	)

	// Emit flow diagnostics (after checker — checker may suppress F002)
	for d in g.flow_result.diagnostics {
		graph_emit(g, d)
	}

	// Emit checker diagnostics
	for d in g.check_result.diagnostics {
		graph_emit(g, d)
	}

	g.checked = true
}

// Phase 4: Concurrency analysis.
graph_concurrency :: proc(g: ^Analysis_Graph) {
	if !g.bound { graph_bind(g) }

	conc_diagnostics := concurrency.analyze_concurrency(
		g.module, &g.bind_result, g.source, g.file_path, g.allocator,
	)
	for d in conc_diagnostics {
		graph_emit(g, d)
	}
}

// ==================== Query Interface ====================

// Get the Analysis_Pass_Context for post-inference analysis passes.
graph_analysis_context :: proc(g: ^Analysis_Graph) -> checker.Analysis_Pass_Context {
	expr_types: ^map[rawptr]checker.Type_ID = nil
	reg: ^checker.Type_Registry = nil
	if g.checked {
		expr_types = &g.check_result.expr_types
		reg = &g.registry
	}
	return checker.build_analysis_pass_context(
		g.module, &g.bind_result, g.file_path, g.allocator,
		expr_types, reg,
	)
}

// Count errors in the accumulated diagnostics.
graph_error_count :: proc(g: ^Analysis_Graph) -> int {
	count := 0
	for d in g.diagnostics {
		if d.severity == .Error { count += 1 }
	}
	return count
}

// Print all accumulated diagnostics, applying level and confidence filtering.
graph_print_diagnostics :: proc(
	g: ^Analysis_Graph,
	level: Analysis_Level = .Strict,
	show_confidence: bool = false,
	min_confidence: core.Confidence = .Unknown,
	sarif_diags: ^[dynamic]core.Diagnostic = nil,
) -> int {
	source_lines := strings.split(g.source, "\n")
	error_count := 0

	for d in g.diagnostics {
		if !should_emit_at_level(d.code, level) { continue }
		if is_line_suppressed(d.code, d.location.line, source_lines) { continue }
		if min_confidence != .Unknown {
			conf := d.confidence
			if conf == .Unknown { conf = core.resolve_confidence(d.code) }
			if u8(conf) > u8(min_confidence) { continue }
			if conf == .Unknown { continue }
		}
		if sarif_diags != nil {
			append(sarif_diags, d)
		} else {
			if show_confidence {
				core.diagnostic_print_with_confidence(d)
			} else {
				core.diagnostic_print(d)
			}
		}
		if d.severity == .Error { error_count += 1 }
	}

	return error_count
}
