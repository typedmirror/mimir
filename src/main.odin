package mimir

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "core"
import "parser"
import "binder"
import "flow"
import "checker"
import "conform"
import "modules"
import "platform"
import "lint"
import "security"
import "concurrency"
import "perf"
import "safety"
import "lsp"
import "migration"
import "codegen"
import "gpu"
import "wasm"

main :: proc() {
	args := os.args
	if len(args) < 2 {
		print_usage()
		os.exit(1)
	}

	command := args[1]

	// L18: global --help/-h support
	if command == "--help" || command == "-h" {
		print_usage()
		return
	}

	switch command {
	case "check":
		cmd_check(args[2:])
	case "format":
		cmd_format(args[2:])
	case "conform":
		conform.cmd_conform(args[2:])
	case "run":
		cmd_run(args[2:])
	case "serve":
		cmd_serve(args[2:])
	case "add":
		cmd_add(args[2:])
	case "lock":
		cmd_lock(args[2:])
	case "install":
		cmd_install(args[2:])
	case "audit":
		cmd_audit(args[2:])
	case "lint":
		cmd_lint(args[2:])
	case "perf":
		cmd_perf(args[2:])
	case "test":
		cmd_test(args[2:])
	case "repl":
		cmd_repl(args[2:])
	case "safety":
		cmd_safety(args[2:])
	case "lsp":
		cmd_lsp()
	case "remove":
		cmd_remove(args[2:])
	case "update":
		cmd_update(args[2:])
	case "build":
		cmd_build(args[2:])
	case "publish":
		cmd_publish(args[2:])
	case "migrate":
		cmd_migrate(args[2:])
	case "import-config":
		cmd_import_config(args[2:])
	case "python":
		cmd_python(args[2:])
	case "stubs":
		cmd_stubs(args[2:])
	case "generate-contracts":
		cmd_generate_contracts(args[2:])
	case "generate-tests":
		cmd_generate_tests(args[2:])
	case "gpu":
		cmd_gpu(args[2:])
	case "compile-gpu":
		cmd_compile_gpu(args[2:])
	case "compile-wasm":
		cmd_compile_wasm(args[2:])
	case "explain":
		platform.cmd_explain(args[2:])
	case "task":
		cmd_task(args[2:])
	case "deps":
		cmd_deps(args[2:])
	case "query":
		cmd_query(args[2:])
	case "cache":
		cmd_cache(args[2:])
	case "report":
		cmd_report(args[2:])
	case "generate-schema":
		cmd_generate_schema(args[2:])
	case "profile-plan":
		cmd_profile_plan(args[2:])
	case "profile":
		cmd_profile_run(args[2:])
	case "diff-with":
		cmd_diff_with(args[2:])
	case "docs":
		cmd_docs(args[2:])
	case "changelog":
		cmd_changelog(args[2:])
	case "version":
		cmd_version()
	case "help":
		print_usage()
	case:
		fmt.eprintfln("mimir: unknown command '%s'", command)
		fmt.eprintfln("Run 'mimir help' for usage.")
		os.exit(1)
	}
}

MIMIR_VERSION :: #config(MIMIR_VERSION, "0.0.1-dev")

cmd_version :: proc() {
	fmt.printfln("mimir %s", MIMIR_VERSION)
}

cmd_task :: proc(args: []string) {
	config := platform.load_project_config()
	if config == nil {
		fmt.eprintfln("mimir task: no mimir.toml found")
		os.exit(1)
	}

	tasks := platform.get_tasks(config)
	if tasks == nil || len(tasks) == 0 {
		fmt.eprintfln("mimir task: no [tasks] section in mimir.toml")
		os.exit(1)
	}

	if len(args) == 0 {
		fmt.printfln("Available tasks:")
		for name, cmd in tasks {
			fmt.printfln("  %-20s %s", name, cmd)
		}
		return
	}

	task_name := args[0]
	cmd_str, found := tasks[task_name]
	if !found {
		fmt.eprintfln("mimir task: unknown task '%s'", task_name)
		fmt.eprintfln("Available tasks:")
		for name in tasks {
			fmt.eprintfln("  %s", name)
		}
		os.exit(1)
	}

	// Execute via shell
	shell_args := [?]string{"-c", cmd_str}
	desc := os.Process_Desc{
		command = {"/bin/sh", shell_args[0], shell_args[1]},
		stdin  = os.stdin,
		stdout = os.stdout,
		stderr = os.stderr,
	}
	process, proc_err := os.process_start(desc)
	if proc_err != nil {
		fmt.eprintfln("mimir task: failed to start: %v", proc_err)
		os.exit(1)
	}
	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		fmt.eprintfln("mimir task: process error: %v", wait_err)
		os.exit(1)
	}
	os.exit(int(state.exit_code))
}

cmd_deps :: proc(args: []string) {
	target := "."
	if len(args) > 0 && args[0] != "usage" { target = args[0] }

	// Check for "mimir deps usage [.]" subcommand
	is_usage := false
	for arg in args {
		if arg == "usage" { is_usage = true }
	}

	p: Pipeline; ok := pipeline_start("deps", target, &p)
	if !ok { return }
	defer pipeline_stop(&p)

	alloc := p.arena.allocator

	// Load project config and lockfile
	config := platform.load_project_config()
	declared := make(map[string]bool, 16, alloc)
	if config != nil {
		deps := platform.get_dependencies(config)
		for name in deps {
			declared[platform.normalize_pkg_name(name)] = true
		}
	}

	// Load lockfile for ghost dep detection
	transitive := make(map[string]bool, 32, alloc)
	if config != nil {
		lock_path := platform.lockfile_path(config.file_path, alloc)
		lf, lf_err := platform.read_lockfile(lock_path, alloc)
		if lf_err == nil {
			for pkg in lf.packages {
				transitive[platform.normalize_pkg_name(pkg.name)] = true
			}
		}
	}

	// Collect imports from all project files
	imported := make(map[string]bool, 32, alloc)
	// For usage mode: track import counts per package
	import_counts := make(map[string]int, 32, alloc)

	for file in p.files {
		module := pipeline_parse_file(&p, "deps", file)
		if module == nil { continue }
		bind_result := binder.bind(module, file, alloc)
		for &imp in bind_result.imports {
			if imp.level > 0 { continue } // skip relative imports
			top := platform.top_level_module(imp.module_name)
			if len(top) == 0 { continue }
			if platform.is_stdlib_module(top) { continue }
			if strings.has_prefix(top, "mimir") { continue }
			imported[top] = true
			if is_usage {
				// Count imported symbols
				n := len(imp.names) if len(imp.names) > 0 else 1
				import_counts[top] = (import_counts[top] or_else 0) + n
			}
		}
	}

	if is_usage {
		// Usage report: imported symbols per package
		fmt.printfln("Package usage:")
		for name in imported {
			count := import_counts[name] or_else 0
			status := "declared"
			norm := platform.normalize_pkg_name(name)
			if !(norm in declared) {
				if norm in transitive {
					status = "ghost (transitive)"
				} else {
					status = "undeclared"
				}
			}
			fmt.printfln("  %-20s %3d symbols imported  [%s]", name, count, status)
		}
		return
	}

	// Standard deps report
	ghost_count := 0
	unused_count := 0
	missing_count := 0

	// Ghost deps: imported, in transitive but not direct
	for name in imported {
		norm := platform.normalize_pkg_name(name)
		if norm in declared { continue }
		if norm in transitive {
			if ghost_count == 0 { fmt.printfln("Ghost dependencies (transitive deps used directly — add to mimir.toml):") }
			fmt.printfln("  %s  [DEP001]", name)
			ghost_count += 1
		}
	}

	// Unused: declared but not imported
	for name in declared {
		found := false
		for iname in imported {
			if platform.normalize_pkg_name(iname) == name {
				found = true
				break
			}
		}
		if !found {
			if unused_count == 0 { fmt.printfln("Unused (in mimir.toml but not imported):") }
			fmt.printfln("  %s", name)
			unused_count += 1
		}
	}

	// Missing: imported, not in any dep list
	for name in imported {
		norm := platform.normalize_pkg_name(name)
		if norm in declared { continue }
		if norm in transitive { continue } // already reported as ghost
		if missing_count == 0 { fmt.printfln("Missing (imported but not declared):") }
		fmt.printfln("  %s", name)
		missing_count += 1
	}

	if ghost_count == 0 && unused_count == 0 && missing_count == 0 {
		fmt.printfln("mimir deps: all dependencies aligned (%d declared, %d imported)", len(declared), len(imported))
	}
}

cmd_cache :: proc(args: []string) {
	if len(args) == 0 {
		fmt.eprintln("mimir cache: no subcommand specified")
		fmt.eprintln("Usage:")
		fmt.eprintln("  mimir cache list              — show cached packages")
		fmt.eprintln("  mimir cache gc                — remove packages not in current lockfile")
		fmt.eprintln("  mimir cache clean             — remove all cached packages")
		os.exit(1)
	}

	arena: core.Analysis_Arena
	arena_err := core.arena_init(&arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize arena")
		os.exit(1)
	}
	defer core.arena_destroy(&arena)
	allocator := arena.allocator

	cache, cache_err := platform.init_cache(allocator)
	if cache_err != nil {
		fmt.eprintfln("mimir cache: %s", platform.error_msg(cache_err))
		os.exit(1)
	}

	switch args[0] {
	case "list":
		entries := platform.list_cache(&cache, allocator)
		if len(entries) == 0 {
			fmt.printfln("Cache is empty (%s)", cache.root)
			return
		}
		fmt.printfln("Cached packages (%s):", cache.root)
		versioned := 0
		cas_count := 0
		for entry in entries {
			if entry.is_cas {
				fmt.printfln("  [cas] %s", entry.name)
				cas_count += 1
			} else if len(entry.version) > 0 {
				fmt.printfln("  %s==%s", entry.name, entry.version)
				versioned += 1
			} else {
				fmt.printfln("  %s (unversioned)", entry.name)
				versioned += 1
			}
		}
		fmt.printfln("  %d versioned, %d CAS entries", versioned, cas_count)

	case "gc":
		// Find lockfile
		cwd, cwd_err := os.get_working_directory(allocator)
		if cwd_err != nil { cwd = "." }
		config_path, config_found := platform.find_config(cwd, allocator)
		if !config_found {
			fmt.eprintln("mimir cache gc: no mimir.toml found — cannot determine which packages to keep")
			fmt.eprintln("  use 'mimir cache clean' to remove all cached packages")
			os.exit(1)
		}

		lock_path := platform.lockfile_path(config_path, allocator)
		lf, lf_err := platform.read_lockfile(lock_path, allocator)
		if lf_err != nil {
			fmt.eprintln("mimir cache gc: no mimir.lock found — run 'mimir lock' first")
			os.exit(1)
		}

		removed, gc_err := platform.gc_cache(&cache, &lf, allocator)
		if gc_err != nil {
			fmt.eprintfln("mimir cache gc: %s", platform.error_msg(gc_err))
			os.exit(1)
		}

		if removed == 0 {
			fmt.printfln("mimir cache gc: nothing to remove (all packages in lockfile)")
		} else {
			fmt.printfln("mimir cache gc: removed %d package(s)", removed)
		}

	case "clean":
		removed, clean_err := platform.clean_cache(&cache, allocator)
		if clean_err != nil {
			fmt.eprintfln("mimir cache clean: %s", platform.error_msg(clean_err))
			os.exit(1)
		}
		if removed == 0 {
			fmt.printfln("mimir cache clean: cache already empty")
		} else {
			fmt.printfln("mimir cache clean: removed %d package(s)", removed)
		}

	case:
		fmt.eprintfln("mimir cache: unknown subcommand '%s'", args[0])
		fmt.eprintln("Available: list, gc, clean")
		os.exit(1)
	}
}

cmd_query :: proc(args: []string) {
	if len(args) == 0 {
		fmt.eprintln("mimir query: no subcommand specified")
		fmt.eprintln("Usage:")
		fmt.eprintln("  mimir query type <name> <file>      — resolve symbol type")
		fmt.eprintln("  mimir query symbols <file>           — list all symbols with types")
		fmt.eprintln("  mimir query callers <name> <file>    — find call sites of a function")
		fmt.eprintln("  mimir query imports <file>           — list all imports")
		fmt.eprintln("  mimir query exports <file>           — list module-level symbols")
		os.exit(1)
	}

	subcmd := args[0]
	switch subcmd {
	case "type":
		if len(args) < 3 {
			fmt.eprintln("mimir query type: requires <name> <file>")
			os.exit(1)
		}
		query_type(args[1], args[2])
	case "symbols":
		if len(args) < 2 {
			fmt.eprintln("mimir query symbols: requires <file>")
			os.exit(1)
		}
		query_symbols(args[1])
	case "callers":
		if len(args) < 3 {
			fmt.eprintln("mimir query callers: requires <name> <file>")
			os.exit(1)
		}
		query_callers(args[1], args[2])
	case "imports":
		if len(args) < 2 {
			fmt.eprintln("mimir query imports: requires <file>")
			os.exit(1)
		}
		query_imports(args[1])
	case "exports":
		if len(args) < 2 {
			fmt.eprintln("mimir query exports: requires <file>")
			os.exit(1)
		}
		query_exports(args[1])
	case:
		fmt.eprintfln("mimir query: unknown subcommand '%s'", subcmd)
		fmt.eprintln("Available: type, symbols, callers, imports, exports")
		os.exit(1)
	}
}

// Run full analysis pipeline on a single file and return results.
@(private = "file")
Query_Result :: struct {
	module:       ^parser.Module,
	bind_result:  binder.Bind_Result,
	flow_result:  flow.Flow_Result,
	check_result: checker.Check_Result,
	file:         string,
}

@(private = "file")
query_analyze :: proc(file: string, p: ^Pipeline) -> (Query_Result, bool) {
	module := pipeline_parse_file(p, "query", file)
	if module == nil { return {}, false }

	alloc := p.arena.allocator
	bind_result := binder.bind(module, file, alloc)
	flow_result := flow.analyze(module, &bind_result, file, alloc)
	check_result := checker.check(module, &bind_result, &flow_result, file, alloc)

	return Query_Result{
		module       = module,
		bind_result  = bind_result,
		flow_result  = flow_result,
		check_result = check_result,
		file         = file,
	}, true
}

@(private = "file")
query_type :: proc(name: string, file: string) {
	p: Pipeline
	// Single-file pipeline
	bridge, bridge_err := parser.bridge_start()
	if bridge_err != nil {
		fmt.eprintln("mimir: failed to start parser")
		os.exit(1)
	}
	defer parser.bridge_stop(&bridge)
	p.bridge = bridge

	arena_err := core.arena_init(&p.arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize arena")
		os.exit(1)
	}
	defer core.arena_destroy(&p.arena)

	qr, ok := query_analyze(file, &p)
	if !ok { os.exit(1) }

	// Find the symbol by name (skip builtins — they have line 0)
	found := false
	for sym in qr.bind_result.symbols {
		if sym.name == name && sym.def_loc.line > 0 {
			type_id, has_type := qr.check_result.symbol_types[sym.id]
			if has_type && type_id != checker.TYPE_UNKNOWN {
				type_str := checker.type_to_string(&qr.check_result.registry, type_id)
				fmt.printfln("%s: %s", name, type_str)
			} else {
				fmt.printfln("%s: <unknown>", name)
			}
			found = true
		}
	}
	if !found {
		fmt.eprintfln("mimir query type: symbol '%s' not found in %s", name, file)
		os.exit(1)
	}
}

@(private = "file")
query_symbols :: proc(file: string) {
	p: Pipeline
	bridge, bridge_err := parser.bridge_start()
	if bridge_err != nil {
		fmt.eprintln("mimir: failed to start parser")
		os.exit(1)
	}
	defer parser.bridge_stop(&bridge)
	p.bridge = bridge

	arena_err := core.arena_init(&p.arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize arena")
		os.exit(1)
	}
	defer core.arena_destroy(&p.arena)

	qr, ok := query_analyze(file, &p)
	if !ok { os.exit(1) }

	// List user-defined symbols with types (skip builtins at line 0)
	fmt.printfln("Symbols in %s:", file)
	for sym in qr.bind_result.symbols {
		if len(sym.name) == 0 { continue }
		if sym.def_loc.line == 0 { continue } // skip builtins

		type_str := "<unknown>"
		if type_id, has := qr.check_result.symbol_types[sym.id]; has && type_id != checker.TYPE_UNKNOWN {
			type_str = checker.type_to_string(&qr.check_result.registry, type_id)
		}

		kind_str := ""
		#partial switch sym.kind {
		case .Variable:  kind_str = "var"
		case .Function:  kind_str = "func"
		case .Class:     kind_str = "class"
		case .Parameter: kind_str = "param"
		case .Import:    kind_str = "import"
		case:            kind_str = "other"
		}

		fmt.printfln("  %-8s %-20s : %s", kind_str, sym.name, type_str)
	}
}

@(private = "file")
query_callers :: proc(name: string, file: string) {
	p: Pipeline
	bridge, bridge_err := parser.bridge_start()
	if bridge_err != nil {
		fmt.eprintln("mimir: failed to start parser")
		os.exit(1)
	}
	defer parser.bridge_stop(&bridge)
	p.bridge = bridge

	arena_err := core.arena_init(&p.arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize arena")
		os.exit(1)
	}
	defer core.arena_destroy(&p.arena)

	qr, ok := query_analyze(file, &p)
	if !ok { os.exit(1) }

	// Find the target symbol (user-defined, skip builtins)
	target_id := binder.INVALID_SYMBOL
	for sym in qr.bind_result.symbols {
		if sym.name == name && sym.def_loc.line > 0 && (sym.kind == .Function || sym.kind == .Class) {
			target_id = sym.id
			break
		}
	}
	if target_id == binder.INVALID_SYMBOL {
		fmt.eprintfln("mimir query callers: function '%s' not found in %s", name, file)
		os.exit(1)
	}

	// Scan all refs — find call sites via binder ref map
	call_count := 0
	_check_call_expr :: proc(expr: parser.Expr, target_id: binder.Symbol_ID, br: ^binder.Bind_Result, file: string, count: ^int) {
		if expr == nil { return }
		if call, ok := expr.(^parser.Call_Expr); ok {
			if name_expr, nok := call.func.(^parser.Name_Expr); nok {
				if ref_id, has := binder.get_ref(br, rawptr(name_expr)); has {
					if ref_id == target_id {
						fmt.printfln("  %s:%d:%d", file, name_expr.loc.line, name_expr.loc.col)
						count^ += 1
					}
				}
			}
		}
	}
	_scan_calls :: proc(stmts: []parser.Stmt, target_id: binder.Symbol_ID, br: ^binder.Bind_Result, file: string, count: ^int) {
		for stmt in stmts {
			#partial switch s in stmt {
			case ^parser.Expr_Stmt:
				_check_call_expr(s.value, target_id, br, file, count)
			case ^parser.Assign:
				_check_call_expr(s.value, target_id, br, file, count)
			case ^parser.Ann_Assign:
				if s.value != nil {
					_check_call_expr(s.value, target_id, br, file, count)
				}
			case ^parser.Return_Stmt:
				if s.value != nil {
					_check_call_expr(s.value, target_id, br, file, count)
				}
			case ^parser.Func_Def:
				_scan_calls(s.body, target_id, br, file, count)
			case ^parser.Class_Def:
				_scan_calls(s.body, target_id, br, file, count)
			case ^parser.If_Stmt:
				_scan_calls(s.body, target_id, br, file, count)
				_scan_calls(s.orelse, target_id, br, file, count)
			case ^parser.For_Stmt:
				_scan_calls(s.body, target_id, br, file, count)
			case ^parser.While_Stmt:
				_scan_calls(s.body, target_id, br, file, count)
			case ^parser.Try_Stmt:
				_scan_calls(s.body, target_id, br, file, count)
				_scan_calls(s.orelse, target_id, br, file, count)
				_scan_calls(s.finalbody, target_id, br, file, count)
			case ^parser.With_Stmt:
				_scan_calls(s.body, target_id, br, file, count)
			}
		}
	}

	fmt.printfln("Call sites for '%s' in %s:", name, file)
	_scan_calls(qr.module.body, target_id, &qr.bind_result, file, &call_count)
	if call_count == 0 {
		fmt.printfln("  (no call sites found)")
	} else {
		fmt.printfln("  %d call site(s)", call_count)
	}
}

@(private = "file")
query_imports :: proc(file: string) {
	p: Pipeline
	bridge, bridge_err := parser.bridge_start()
	if bridge_err != nil {
		fmt.eprintln("mimir: failed to start parser")
		os.exit(1)
	}
	defer parser.bridge_stop(&bridge)
	p.bridge = bridge

	arena_err := core.arena_init(&p.arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize arena")
		os.exit(1)
	}
	defer core.arena_destroy(&p.arena)

	module := pipeline_parse_file(&p, "query", file)
	if module == nil { os.exit(1) }

	bind_result := binder.bind(module, file, p.arena.allocator)

	fmt.printfln("Imports in %s:", file)
	for imp in bind_result.imports {
		if imp.is_star {
			fmt.printfln("  from %s import *", imp.module_name)
		} else if len(imp.names) == 0 {
			fmt.printfln("  import %s", imp.module_name)
		} else {
			for n in imp.names {
				if len(n.alias) > 0 {
					fmt.printfln("  from %s import %s as %s", imp.module_name, n.name, n.alias)
				} else {
					fmt.printfln("  from %s import %s", imp.module_name, n.name)
				}
			}
		}
	}
	if len(bind_result.imports) == 0 {
		fmt.printfln("  (no imports)")
	}
}

@(private = "file")
query_exports :: proc(file: string) {
	p: Pipeline
	bridge, bridge_err := parser.bridge_start()
	if bridge_err != nil {
		fmt.eprintln("mimir: failed to start parser")
		os.exit(1)
	}
	defer parser.bridge_stop(&bridge)
	p.bridge = bridge

	arena_err := core.arena_init(&p.arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize arena")
		os.exit(1)
	}
	defer core.arena_destroy(&p.arena)

	qr, ok := query_analyze(file, &p)
	if !ok { os.exit(1) }

	// Module-level symbols (module scope + user-defined)
	fmt.printfln("Exports from %s:", file)
	count := 0
	module_scope := qr.bind_result.module_scope
	for sym in qr.bind_result.symbols {
		if len(sym.name) == 0 { continue }
		if sym.def_loc.line == 0 { continue } // skip builtins
		if sym.name[0] == '_' { continue } // private by convention
		if sym.scope_id != module_scope { continue } // only module-level

		type_str := "<unknown>"
		if type_id, has := qr.check_result.symbol_types[sym.id]; has && type_id != checker.TYPE_UNKNOWN {
			type_str = checker.type_to_string(&qr.check_result.registry, type_id)
		}

		kind_str := ""
		#partial switch sym.kind {
		case .Variable:  kind_str = "var"
		case .Function:  kind_str = "func"
		case .Class:     kind_str = "class"
		case .Import:    kind_str = "import"
		case:            kind_str = "other"
		}

		fmt.printfln("  %-8s %-20s : %s", kind_str, sym.name, type_str)
		count += 1
	}
	if count == 0 {
		fmt.printfln("  (no public exports)")
	}
}

cmd_report :: proc(args: []string) {
	target := "."
	if len(args) > 0 { target = args[0] }

	p: Pipeline; ok := pipeline_start("report", target, &p)
	if !ok { return }
	defer pipeline_stop(&p)

	// Aggregate diagnostics across all passes
	counts := make(map[string]int, 16, p.arena.allocator) // code → count
	category_counts := make(map[string]int, 8, p.arena.allocator) // category → count
	files_with_issues := make(map[string]bool, 16, p.arena.allocator)
	total := 0

	_count :: proc(d: core.Diagnostic, counts: ^map[string]int, cat_counts: ^map[string]int, file_set: ^map[string]bool, total: ^int) {
		counts[d.code] = (counts[d.code] if d.code in counts^ else 0) + 1
		cat := _diag_category(d)
		cat_counts[cat] = (cat_counts[cat] if cat in cat_counts^ else 0) + 1
		file_set[d.location.file] = true
		total^ += 1
	}

	for file in p.files {
		module := pipeline_parse_file(&p, "report", file)
		if module == nil { continue }

		bind_result := binder.bind(module, file, p.arena.allocator)
		for d in bind_result.diagnostics { _count(d, &counts, &category_counts, &files_with_issues, &total) }

		flow_result := flow.analyze(module, &bind_result, file, p.arena.allocator)
		for d in flow_result.diagnostics { _count(d, &counts, &category_counts, &files_with_issues, &total) }

		check_result := checker.check(module, &bind_result, &flow_result, file, p.arena.allocator)
		for d in check_result.diagnostics { _count(d, &counts, &category_counts, &files_with_issues, &total) }

		source_data, _ := os.read_entire_file(file, p.arena.allocator)
		source_str := string(source_data) if source_data != nil else ""

		conc_diags := concurrency.analyze_concurrency(module, &bind_result, source_str, file, p.arena.allocator)
		for d in conc_diags { _count(d, &counts, &category_counts, &files_with_issues, &total) }

		perf_config := perf.default_config()
		perf_diags := perf.analyze_performance(module, &bind_result, source_str, file, &perf_config, p.arena.allocator)
		for d in perf_diags { _count(d, &counts, &category_counts, &files_with_issues, &total) }

		safety_config := safety.default_config()
		safety_diags := safety.analyze_safety(module, &bind_result, file, &safety_config, p.arena.allocator)
		for d in safety_diags { _count(d, &counts, &category_counts, &files_with_issues, &total) }
	}

	// Print summary
	fmt.printfln("\nmimir report: %d file(s) analyzed\n", len(p.files))
	CATEGORIES :: [?]string{"Type", "Security", "Performance", "Concurrency", "Safety", "Binding", "Flow", "Other"}
	for cat in CATEGORIES {
		n := category_counts[cat] if cat in category_counts else 0
		if n > 0 {
			fmt.printfln("  %-15s %d", cat, n)
		}
	}
	fmt.printfln("\n  Total:          %d issues in %d file(s)", total, len(files_with_issues))
}

_diag_category :: proc(d: core.Diagnostic) -> string {
	if len(d.code) >= 1 {
		if d.code[0] == 'T' { return "Type" }
		if d.code[0] == 'B' { return "Binding" }
		if d.code[0] == 'F' { return "Flow" }
	}
	if len(d.code) >= 3 {
		prefix := d.code[:3]
		if prefix == "SEC" { return "Security" }
		if prefix == "CON" { return "Concurrency" }
		if prefix == "PER" { return "Performance" }
		if prefix == "SAF" { return "Safety" }
		if prefix == "ML0" { return "Type" }
		if prefix == "MAT" { return "Type" }
		if prefix == "DAT" { return "Type" }
		if prefix == "HTT" { return "Type" }
		if prefix == "JSO" { return "Type" }
		if prefix == "SER" { return "Security" }
		if prefix == "REG" { return "Type" }
		if prefix == "TIM" { return "Type" }
		if prefix == "ENC" { return "Type" }
		if prefix == "API" { return "Type" }
		if prefix == "COM" { return "Type" }
		if prefix == "DEP" { return "Type" }
		if prefix == "MIG" { return "Other" }
		if prefix == "CRY" { return "Security" }
		if prefix == "GPU" { return "Other" }
		if prefix == "SHA" { return "Type" }
	}
	if len(d.code) >= 1 && d.code[0] == 'D' { return "Flow" }
	if len(d.code) >= 1 && d.code[0] == 'L' { return "Other" }
	if len(d.code) >= 1 && d.code[0] == 'C' { return "Other" }
	if len(d.code) >= 1 && d.code[0] == 'S' { return "Other" }
	return "Other"
}

// §24: Static hotspot prediction — runs perf analysis with ranked output
cmd_profile_plan :: proc(args: []string) {
	target := "."
	if len(args) > 0 { target = args[0] }

	p: Pipeline; ok := pipeline_start("profile-plan", target, &p)
	if !ok { return }
	defer pipeline_stop(&p)

	Hotspot :: struct { file: string, line: int, code: string, what: string }
	hotspots := make([dynamic]Hotspot, 0, 32, p.arena.allocator)

	for file in p.files {
		module := pipeline_parse_file(&p, "profile-plan", file)
		if module == nil { continue }
		bind_result := binder.bind(module, file, p.arena.allocator)
		source_data, _ := os.read_entire_file(file, p.arena.allocator)
		source_str := string(source_data) if source_data != nil else ""
		perf_config := perf.default_config()
		diags := perf.analyze_performance(module, &bind_result, source_str, file, &perf_config, p.arena.allocator)
		for d in diags {
			append(&hotspots, Hotspot{file = d.location.file, line = d.location.line, code = d.code, what = d.what})
		}
	}

	if len(hotspots) == 0 {
		fmt.printfln("mimir profile-plan: no performance hotspots found in %d file(s)", len(p.files))
		return
	}

	fmt.printfln("mimir profile-plan: %d hotspot(s) in %d file(s)\n", len(hotspots), len(p.files))
	for hs, i in hotspots {
		fmt.printfln("  %d. %s:%d [%s] %s", i + 1, hs.file, hs.line, hs.code, hs.what)
	}
}

// §24.2 — Run Python script with cProfile and correlate with static hotspots
cmd_profile_run :: proc(args: []string) {
	if len(args) < 1 {
		fmt.eprintln("Usage: mimir profile run <script.py> [args...]")
		fmt.eprintln("Runs the script under cProfile and correlates with static analysis.")
		os.exit(1)
	}

	subcommand := args[0]
	if subcommand != "run" {
		fmt.eprintfln("mimir profile: unknown subcommand '%s'", subcommand)
		fmt.eprintln("Usage: mimir profile run <script.py> [args...]")
		os.exit(1)
	}

	if len(args) < 2 {
		fmt.eprintln("Usage: mimir profile run <script.py>")
		os.exit(1)
	}

	script := args[1]

	// Step 1: Run static analysis (profile-plan)
	fmt.printfln("=== Static Analysis ===")

	p: Pipeline; ok := pipeline_start("profile", script, &p)
	if !ok {
		fmt.printfln("  no Python files found")
	} else {
		defer pipeline_stop(&p)

		module := pipeline_parse_file(&p, "profile", script)
		if module != nil {
			bind_result := binder.bind(module, script, p.arena.allocator)
			source_data, _ := os.read_entire_file(script, p.arena.allocator)
			source_str := string(source_data) if source_data != nil else ""
			perf_config := perf.default_config()
			static_diags := perf.analyze_performance(module, &bind_result, source_str, script, &perf_config, p.arena.allocator)

			if len(static_diags) > 0 {
				fmt.printfln("  %d static hotspot(s):", len(static_diags))
				for d, i in static_diags {
					fmt.printfln("  %d. %s:%d [%s] %s", i + 1, d.location.file, d.location.line, d.code, d.what)
				}
			} else {
				fmt.printfln("  no static hotspots found")
			}
		}
	}
	fmt.println()

	// Step 2: Run script under cProfile
	fmt.printfln("=== Runtime Profile (cProfile) ===")

	python, py_ok := platform.find_python("", context.allocator)
	if !py_ok {
		fmt.eprintln("mimir profile: no Python interpreter found")
		os.exit(1)
	}

	prof_args := make([dynamic]string, 0, 8)
	append(&prof_args, python)
	append(&prof_args, "-m")
	append(&prof_args, "cProfile")
	append(&prof_args, "-s")
	append(&prof_args, "cumulative")
	append(&prof_args, script)
	for i := 2; i < len(args); i += 1 {
		append(&prof_args, args[i])
	}

	_, prof_stdout, _, exec_err := os.process_exec(
		{command = prof_args[:]},
		context.allocator,
	)

	if exec_err != nil {
		fmt.eprintfln("mimir profile: failed to run cProfile: %v", exec_err)
		os.exit(1)
	}

	if prof_stdout != nil {
		fmt.println(string(prof_stdout))
	}

	fmt.printfln("mimir profile: static analysis + cProfile complete for %s", script)
}

// Run both mimir and mypy on the same files, show the delta
cmd_diff_with :: proc(args: []string) {
	if len(args) < 2 {
		fmt.eprintln("Usage: mimir diff-with mypy <path>")
		os.exit(1)
	}
	tool := args[0]
	target := args[1]

	if tool != "mypy" {
		fmt.eprintfln("mimir diff-with: unsupported tool '%s' (only 'mypy' supported)", tool)
		os.exit(1)
	}

	// Run mimir check
	p: Pipeline; ok := pipeline_start("diff-with", target, &p)
	if !ok { return }
	defer pipeline_stop(&p)

	mimir_diags := make([dynamic]core.Diagnostic, 0, 32, p.arena.allocator)
	for file in p.files {
		module := pipeline_parse_file(&p, "diff-with", file)
		if module == nil { continue }
		bind_result := binder.bind(module, file, p.arena.allocator)
		flow_result := flow.analyze(module, &bind_result, file, p.arena.allocator)
		check_result := checker.check(module, &bind_result, &flow_result, file, p.arena.allocator)
		for d in check_result.diagnostics {
			if d.severity == .Error { append(&mimir_diags, d) }
		}
	}

	// Run mypy
	mypy_args := make([dynamic]string, 0, 4, p.arena.allocator)
	append(&mypy_args, "mypy")
	append(&mypy_args, "--no-color-output")
	append(&mypy_args, target)
	_, mypy_stdout, _, exec_err := os.process_exec({command = mypy_args[:]}, p.arena.allocator)

	mypy_lines := 0
	if exec_err == nil && mypy_stdout != nil {
		for b in mypy_stdout {
			if b == '\n' { mypy_lines += 1 }
		}
	}

	fmt.printfln("mimir diff-with mypy:")
	fmt.printfln("  mimir errors: %d", len(mimir_diags))
	fmt.printfln("  mypy errors:  %d", mypy_lines)
	if len(mimir_diags) > mypy_lines {
		fmt.printfln("  mimir catches %d more issue(s)", len(mimir_diags) - mypy_lines)
	} else if mypy_lines > len(mimir_diags) {
		fmt.printfln("  mypy catches %d more issue(s)", mypy_lines - len(mimir_diags))
	} else {
		fmt.printfln("  same error count")
	}
}

// Generate documentation from type info
cmd_docs :: proc(args: []string) {
	target := "."
	if len(args) > 0 { target = args[0] }

	p: Pipeline; ok := pipeline_start("docs", target, &p)
	if !ok { return }
	defer pipeline_stop(&p)

	total_funcs := 0
	total_classes := 0

	for file in p.files {
		module := pipeline_parse_file(&p, "docs", file)
		if module == nil { continue }
		bind_result := binder.bind(module, file, p.arena.allocator)
		flow_result := flow.analyze(module, &bind_result, file, p.arena.allocator)
		check_result := checker.check(module, &bind_result, &flow_result, file, p.arena.allocator)

		// Extract function and class definitions
		for stmt in module.body {
			#partial switch s in stmt {
			case ^parser.Func_Def:
				total_funcs += 1
				fmt.printfln("## %s", s.name)
				// Parameter types
				fmt.printf("```python\ndef %s(", s.name)
				for arg, i in s.args.args {
					if i > 0 { fmt.print(", ") }
					fmt.print(arg.arg)
					if arg.annotation != nil {
						ann_type := checker.resolve_annotation(arg.annotation, &check_result.registry, &bind_result, nil, nil)
						if ann_type != checker.TYPE_UNKNOWN {
							fmt.printf(": %s", checker.type_to_string(&check_result.registry, ann_type))
						}
					}
				}
				// Return annotation
				if s.returns != nil {
					ret_type := checker.resolve_annotation(s.returns, &check_result.registry, &bind_result, nil, nil)
					if ret_type != checker.TYPE_UNKNOWN {
						fmt.printf(") -> %s", checker.type_to_string(&check_result.registry, ret_type))
					} else {
						fmt.print(")")
					}
				} else {
					fmt.print(")")
				}
				fmt.println("\n```\n")

				// Docstring
				if len(s.body) > 0 {
					if expr_stmt, eok := s.body[0].(^parser.Expr_Stmt); eok {
						if const, cok := expr_stmt.value.(^parser.Constant_Expr); cok {
							if doc, dok := const.value.(string); dok {
								fmt.printfln("%s\n", doc)
							}
						}
					}
				}

			case ^parser.Class_Def:
				total_classes += 1
				fmt.printfln("## class %s\n", s.name)
				// Methods
				for body_stmt in s.body {
					if method, mok := body_stmt.(^parser.Func_Def); mok {
						fmt.printf("- `%s(", method.name)
						first := true
						for arg in method.args.args {
							if arg.arg == "self" { continue }
							if !first { fmt.print(", ") }
							first = false
							fmt.print(arg.arg)
						}
						fmt.println(")`")
					}
				}
				fmt.println()
			}
		}
	}

	fmt.eprintfln("mimir docs: %d function(s), %d class(es) in %d file(s)", total_funcs, total_classes, len(p.files))
}

// Semantic changelog — diff type signatures between current and a git ref
cmd_changelog :: proc(args: []string) {
	since := ""
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--since" && i + 1 < len(args) {
			since = args[i + 1]
			i += 1
		}
	}

	if since == "" {
		fmt.eprintln("Usage: mimir changelog --since <git-ref>")
		fmt.eprintln("Example: mimir changelog --since v1.0")
		os.exit(1)
	}

	// Get list of changed Python files since the ref
	diff_cmd := [?]string{"git", "diff", "--name-only", since, "--", "*.py"}
	_, git_stdout, _, exec_err := os.process_exec({command = diff_cmd[:]}, context.temp_allocator)

	if exec_err != nil {
		fmt.eprintfln("mimir changelog: failed to run git diff: %v", exec_err)
		os.exit(1)
	}

	if git_stdout == nil || len(git_stdout) == 0 {
		fmt.printfln("mimir changelog: no Python files changed since '%s'", since)
		return
	}

	// Parse changed file list
	changed := string(git_stdout)
	count := 0
	for b in changed {
		if b == '\n' { count += 1 }
	}

	fmt.printfln("mimir changelog --since %s:", since)
	fmt.printfln("  %d Python file(s) changed", count)
	fmt.printfln("\n  (detailed type-level diff requires comparing type registries across commits)")
	fmt.printfln("  (current implementation: file-level change detection)")
}

cmd_generate_schema :: proc(args: []string) {
	target := "."
	if len(args) > 0 { target = args[0] }

	p: Pipeline; ok := pipeline_start("generate-schema", target, &p)
	if !ok { return }
	defer pipeline_stop(&p)

	all_routes := make([dynamic]checker.Route_Info, 0, 16, p.arena.allocator)

	reg := checker.init_registry(p.arena.allocator)
	vreg := checker.init_virtual_registry(&reg)

	for file in p.files {
		module := pipeline_parse_file(&p, "generate-schema", file)
		if module == nil { continue }

		bind_result := binder.bind(module, file, p.arena.allocator)
		virtual_imports := checker.resolve_virtual_imports(
			&vreg, &bind_result, &reg, nil,
		)

		diags := make([dynamic]core.Diagnostic, 0, 4, p.arena.allocator)
		routes := checker.analyze_routes(module, &bind_result, &reg, &virtual_imports, file, &diags, p.arena.allocator)
		for r in routes { append(&all_routes, r) }
	}

	if len(all_routes) == 0 {
		fmt.eprintfln("mimir generate-schema: no @route handlers found in '%s'", target)
		return
	}

	// Emit OpenAPI 3.0 JSON using printfln with escaped braces
	fmt.printfln("{{")
	fmt.printfln(`  "openapi": "3.0.0",`)
	fmt.printfln(`  "info": {{"title": "API", "version": "1.0.0"}},`)
	fmt.printfln(`  "paths": {{`)

	for route, idx in all_routes {
		oapi_path := route.path
		method_lower := strings.to_lower(route.method, context.temp_allocator)

		fmt.printf(`    "%s": {{"%s": {{"summary": "%s"`, oapi_path, method_lower, route.handler_name)

		if len(route.path_params) > 0 {
			fmt.print(`, "parameters": [`)
			for pp, pi in route.path_params {
				if pi > 0 { fmt.print(",") }
				fmt.printf(`{{"name": "%s", "in": "path", "required": true, "schema": {{"type": "string"}}}}`, pp)
			}
			fmt.print("]")
		}

		fmt.print(`, "responses": {"200": {"description": "OK"}}`)
		fmt.print("}}")
		if idx < len(all_routes) - 1 { fmt.println(",") } else { fmt.println() }
	}

	fmt.printfln("  }}")
	fmt.printfln("}}")
	fmt.eprintfln("mimir generate-schema: %d route(s) → OpenAPI 3.0", len(all_routes))
}

cmd_format :: proc(args: []string) {
	config := platform.default_format_config()
	target := "."

	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--check" {
			config.check_only = true
			i += 1
		} else if arg == "--diff" {
			config.show_diff = true
			i += 1
		} else if arg == "--line-length" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir format: --line-length requires an integer argument")
				os.exit(1)
			}
			// Simple integer parse
			val := 0
			for c in args[i + 1] {
				if c >= '0' && c <= '9' {
					val = val * 10 + int(c - '0')
				}
			}
			if val > 0 { config.line_length = val }
			i += 2
		} else if arg == "--quote-style" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir format: --quote-style requires 'single' or 'double'")
				os.exit(1)
			}
			switch args[i + 1] {
			case "single": config.quote_style = .Single
			case "double": config.quote_style = .Double
			case:
				fmt.eprintfln("mimir format: unknown quote style '%s' (use 'single' or 'double')", args[i + 1])
				os.exit(1)
			}
			i += 2
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintfln("mimir format: unknown flag '%s'", arg)
			fmt.eprintln("Usage: mimir format [--check] [--diff] [--line-length N] [--quote-style single|double] [path]")
			os.exit(1)
		} else {
			target = arg
			i += 1
		}
	}

	p: Pipeline; ok := pipeline_start("format", target, &p)
	if !ok { return }
	defer pipeline_stop(&p)

	changed_count := 0
	for file in p.files {
		// Read source
		source_data, read_err := os.read_entire_file(file, p.arena.allocator)
		if read_err != nil {
			fmt.eprintfln("mimir format: cannot read '%s': %v", file, read_err)
			continue
		}
		source := string(source_data)

		module := pipeline_parse_file(&p, "format", file)
		if module == nil { continue }

		formatted, was_changed := platform.format_file(source, module, &config, p.arena.allocator)

		if was_changed {
			changed_count += 1
			if config.check_only {
				fmt.printfln("would reformat %s", file)
			} else if config.show_diff {
				platform.print_diff(file, source, formatted)
			} else {
				// Write formatted file
				write_err := os.write_entire_file(file, transmute([]byte)formatted)
				if write_err != nil {
					fmt.eprintfln("mimir format: cannot write '%s': %v", file, write_err)
					continue
				}
				fmt.printfln("  reformatted %s", file)
			}
		}
	}

	if config.check_only {
		if changed_count > 0 {
			fmt.printfln("mimir format: %d file(s) would be reformatted", changed_count)
			os.exit(1)
		} else {
			fmt.printfln("mimir format: %d file(s) already formatted", len(p.files))
		}
	} else {
		if changed_count > 0 {
			fmt.printfln("mimir format: reformatted %d file(s)", changed_count)
		} else {
			fmt.printfln("mimir format: %d file(s) already formatted", len(p.files))
		}
	}
}

// §28.4: Gradual adoption levels — filter diagnostics by analysis depth
Analysis_Level :: enum {
	Basic,      // Type errors mypy would catch. Minimal noise.
	Inference,  // Deep inference, unannotated code analysis.
	Security,   // Taint analysis, crypto, secrets, supply chain.
	Strict,     // Everything including performance, style, safety.
}

// Check if a diagnostic should be emitted at the given level
should_emit_at_level :: proc(code: string, level: Analysis_Level) -> bool {
	if level == .Strict { return true }

	// Basic: core type errors (T0xx) + flow errors (F0xx)
	if strings.has_prefix(code, "T") || strings.has_prefix(code, "F") {
		return true
	}

	if level == .Basic { return false }

	// Inference: basic + dead code (D0xx) + constraint diagnostics
	if strings.has_prefix(code, "D") {
		return true
	}

	if level == .Inference { return false }

	// Security: inference + security (SEC) + concurrency (CONC) + taint
	if strings.has_prefix(code, "SEC") || strings.has_prefix(code, "CONC") {
		return true
	}

	return false
}

// §28.3: Check if a diagnostic code is suppressed by an inline comment on the given line.
// Supports: # mimir: ignore (suppress all) and # mimir: ignore[T001] or # mimir: ignore[T001, T002]
is_line_suppressed :: proc(code: string, line_num: int, source_lines: []string) -> bool {
	idx := line_num - 1
	if idx < 0 || idx >= len(source_lines) { return false }
	line := source_lines[idx]
	marker_pos := strings.index(line, "# mimir: ignore")
	if marker_pos < 0 { return false }
	rest := line[marker_pos + len("# mimir: ignore"):]
	if len(rest) == 0 { return true } // blanket suppress
	if rest[0] == '[' {
		end := strings.index(rest, "]")
		if end > 0 {
			codes_str := rest[1:end]
			for part in strings.split(codes_str, ",") {
				if strings.trim_space(part) == code { return true }
			}
		}
	}
	return false
}

cmd_check :: proc(args: []string) {
	if len(args) == 0 {
		fmt.eprintln("mimir check: no input path specified")
		fmt.eprintln("Usage: mimir check [--level basic|inference|security|strict] <path>")
		os.exit(1)
	}

	// Parse flags
	sarif_mode := false
	watch_mode := false
	level := Analysis_Level.Strict  // default: everything
	target := args[0]
	for i := 0; i < len(args); i += 1 {
		if args[i] == "--format" && i + 1 < len(args) {
			if args[i + 1] == "sarif" { sarif_mode = true }
			i += 1
		} else if args[i] == "--level" && i + 1 < len(args) {
			switch args[i + 1] {
			case "basic":     level = .Basic
			case "inference": level = .Inference
			case "security":  level = .Security
			case "strict":    level = .Strict
			case:
				fmt.eprintfln("mimir check: unknown level '%s' (use basic, inference, security, or strict)", args[i + 1])
				os.exit(1)
			}
			i += 1
		} else if args[i] == "--watch" || args[i] == "-w" {
			watch_mode = true
		} else if !strings.has_prefix(args[i], "-") {
			target = args[i]
		}
	}

	if watch_mode {
		cmd_check_watch(target, level)
		return
	}

	p: Pipeline; ok := pipeline_start("check", target, &p)
	if !ok { return }
	defer pipeline_stop(&p)

	// Read level from mimir.toml if not set by CLI flag
	if level == .Strict {
		// .Strict is the default — check if mimir.toml overrides it
		config, config_err := platform.read_config("mimir.toml", p.arena.allocator)
		if config_err == nil && len(config.analysis_level) > 0 {
			switch config.analysis_level {
			case "basic":     level = .Basic
			case "inference": level = .Inference
			case "security":  level = .Security
			case "strict":    // already default
			}
		}
	}

	// SARIF mode: collect all diagnostics, emit JSON at end
	sarif_diags: [dynamic]core.Diagnostic
	if sarif_mode { sarif_diags = make([dynamic]core.Diagnostic, 0, 32, p.arena.allocator) }

	// Single file: fast path (existing behavior)
	errors := 0
	if len(p.files) == 1 {
		errors = cmd_check_single(p.files[0], &p.bridge, &p.arena, sarif_mode ? &sarif_diags : nil, level)
	} else {
		// Multi-module: shared registry + module graph
		errors = cmd_check_multi(target, p.files, &p.bridge, &p.arena, level)
	}

	if sarif_mode {
		fmt.println(core.diagnostics_to_sarif(sarif_diags[:], MIMIR_VERSION))
	} else {
		if errors > 0 { os.exit(1) }
	}
}

// Single-file check — original behavior, unchanged
// Watch mode: re-run check whenever files change.
// Polls file modification times every 1.5 seconds.
cmd_check_watch :: proc(target: string, level: Analysis_Level) {
	fmt.printfln("mimir check --watch: watching '%s' (Ctrl+C to stop)\n", target)

	// Collect initial file mtimes
	files, find_err := core.find_python_files(target)
	if find_err != nil {
		fmt.eprintfln("mimir check: error reading '%s': %v", target, find_err)
		os.exit(1)
	}
	if len(files) == 0 {
		fmt.printfln("mimir check: no Python files found in '%s'", target)
		return
	}

	mtimes := make(map[string]i64, len(files))
	for file in files {
		info, info_err := os.stat(file, context.allocator)
		if info_err == nil {
			mtimes[file] = i64(info.modification_time._nsec)
		}
	}

	// Initial run
	_run_check_once(target, level)

	// Poll loop
	for {
		time.sleep(1500 * time.Millisecond)

		changed := false
		// Re-discover files (handle new files)
		new_files, _ := core.find_python_files(target)
		for file in new_files {
			info, info_err := os.stat(file, context.allocator)
			if info_err != nil { continue }
			mtime := i64(info.modification_time._nsec)
			prev_mtime, has_prev := mtimes[file]
			if !has_prev || mtime != prev_mtime {
				changed = true
				mtimes[file] = mtime
			}
		}

		if changed {
			fmt.printfln("\n--- file change detected, re-checking... ---\n")
			_run_check_once(target, level)
		}
	}
}

_run_check_once :: proc(target: string, level: Analysis_Level) {
	p: Pipeline; ok := pipeline_start("check", target, &p)
	if !ok { return }
	defer pipeline_stop(&p)

	errors := 0
	if len(p.files) == 1 {
		errors = cmd_check_single(p.files[0], &p.bridge, &p.arena, nil, level)
	} else {
		errors = cmd_check_multi(target, p.files, &p.bridge, &p.arena, level)
	}

	if errors > 0 {
		fmt.printfln("\nmimir check: %d error(s)", errors)
	} else {
		fmt.printfln("\nmimir check: all clear")
	}
}

cmd_check_single :: proc(
	file: string,
	bridge: ^parser.Bridge,
	arena: ^core.Analysis_Arena,
	sarif_diags: ^[dynamic]core.Diagnostic = nil,
	level: Analysis_Level = .Strict,
) -> int {
	error_count := 0

	module, parse_err := parser.bridge_parse(bridge, file, arena.allocator)
	if parse_err != nil {
		error_count += 1
		switch e in parse_err {
		case parser.Syntax_Error:
			fmt.eprintfln("%s:%d:%d: error: %s", e.file, e.line, e.col, e.msg)
		case parser.Bridge_Error:
			fmt.eprintfln("mimir: %s: %s", file, e.msg)
		}
		fmt.eprintfln("mimir: 1 file(s) had errors")
		return 1
	}

	// Read source for §28.3 inline suppression
	source_data, _ := os.read_entire_file(file, arena.allocator)
	source_lines := strings.split(string(source_data), "\n")

	_emit_diag :: proc(d: core.Diagnostic, error_count: ^int, sarif_diags: ^[dynamic]core.Diagnostic, level: Analysis_Level, source_lines: []string) {
		if !should_emit_at_level(d.code, level) { return }
		if is_line_suppressed(d.code, d.location.line, source_lines) { return }
		if sarif_diags != nil {
			append(sarif_diags, d)
		} else {
			core.diagnostic_print(d)
		}
		if d.severity == .Error { error_count^ += 1 }
	}

	bind_result := binder.bind(module, file, arena.allocator)
	for d in bind_result.diagnostics {
		_emit_diag(d, &error_count, sarif_diags, level, source_lines)
	}

	flow_result := flow.analyze(module, &bind_result, file, arena.allocator)

	// Resolve third-party imports from package cache
	import_types := make(map[binder.Symbol_ID]checker.Type_ID, 8, arena.allocator)
	registry := checker.init_registry(arena.allocator)
	builtins := checker.init_builtins(&registry)

	pkg_cache, cache_ok := platform.init_cache(arena.allocator)
	if cache_ok == nil {
		// Resolve virtual modules
		vreg := checker.init_virtual_registry(&registry)
		virtual := checker.resolve_virtual_imports(&vreg, &bind_result, &registry)
		for sym_id, type_id in virtual {
			import_types[sym_id] = type_id
		}

		// Resolve third-party imports from cache
		mod_scope := binder.result_get_scope(&bind_result, bind_result.module_scope)
		if mod_scope != nil {
			parsed_pkgs := make(map[string]modules.Module_Exports, 8, arena.allocator)
			for imp in bind_result.imports {
				if imp.level > 0 { continue } // skip relative
				if checker.is_virtual_module(&vreg, imp.module_name) { continue }

				// Check if already parsed
				top := imp.module_name
				for k := 0; k < len(top); k += 1 {
					if top[k] == '.' { top = top[:k]; break }
				}

				if _, already := parsed_pkgs[imp.module_name]; !already {
					pkg_file, found := modules.resolve_package_file(imp.module_name, &pkg_cache, arena.allocator)
					if found {
						pkg_exports, extract_ok := modules.extract_package_exports(
							pkg_file, imp.module_name, bridge, &registry, arena.allocator,
						)
						if extract_ok {
							parsed_pkgs[imp.module_name] = pkg_exports

							// Wire into import_types
							if len(imp.names) == 0 && !imp.is_star {
								// "import X" → Module_Type
								local_name := top
								if sym_id, ok := mod_scope.symbols[local_name]; ok {
									mod_type_id := checker.register_type(&registry, checker.Module_Type{
										name    = imp.module_name,
										exports = pkg_exports.types,
									})
									import_types[sym_id] = mod_type_id
								}
							} else if !imp.is_star {
								// "from X import Y" → look up each name
								for imp_name in imp.names {
									local := imp_name.alias if len(imp_name.alias) > 0 else imp_name.name
									if sym_id, ok := mod_scope.symbols[local]; ok {
										if type_id, found2 := pkg_exports.types[imp_name.name]; found2 {
											import_types[sym_id] = type_id
										}
									}
								}
							}
						}
					}
				}
			}
		}
	}

	check_result := checker.check_with_imports(
		module, &bind_result, &flow_result, file,
		&registry, &builtins, import_types, arena.allocator,
	)

	// Emit flow diagnostics AFTER checker (checker may suppress F002 for Never-returning calls)
	for d in flow_result.diagnostics {
		_emit_diag(d, &error_count, sarif_diags, level, source_lines)
	}
	for d in check_result.diagnostics {
		_emit_diag(d, &error_count, sarif_diags, level, source_lines)
	}

	// Concurrency analysis (reuse already-read source)
	conc_diagnostics := concurrency.analyze_concurrency(module, &bind_result, string(source_data), file, arena.allocator)
	for d in conc_diagnostics {
		_emit_diag(d, &error_count, sarif_diags, level, source_lines)
	}

	if sarif_diags == nil {
		fmt.printfln("  checked %s (%d stmts, %d symbols, %d scopes, %d blocks, %d guards, %d types)",
			file, len(module.body),
			len(bind_result.symbols), len(bind_result.scopes),
			flow.total_blocks(&flow_result), len(flow_result.guards),
			len(check_result.registry.types))

		if error_count > 0 {
			fmt.eprintfln("mimir: 1 file(s) had errors")
		} else {
			fmt.printfln("mimir: successfully checked 1 file(s)")
		}
	}

	return error_count
}

// Multi-module check — shared registry, import resolution
cmd_check_multi :: proc(
	root_path: string,
	files: []string,
	bridge: ^parser.Bridge,
	arena: ^core.Analysis_Arena,
	level: Analysis_Level = .Strict,
) -> int {
	// 1. Init shared registry + builtins
	registry := checker.init_registry(arena.allocator)
	builtins := checker.init_builtins(&registry)

	// 2. Discover modules
	graph := modules.discover_modules(root_path, files, arena.allocator)

	// 3. Parse all files
	parse_errors := 0
	for _, info in graph.modules {
		module, parse_err := parser.bridge_parse(bridge, info.file_path, arena.allocator)
		if parse_err != nil {
			parse_errors += 1
			switch e in parse_err {
			case parser.Syntax_Error:
				fmt.eprintfln("%s:%d:%d: error: %s", e.file, e.line, e.col, e.msg)
			case parser.Bridge_Error:
				fmt.eprintfln("mimir: %s: %s", info.file_path, e.msg)
			}
			continue
		}
		info.parse_result = module
	}

	// 4. Bind all files
	for _, info in graph.modules {
		if info.parse_result == nil { continue }
		info.bind_result = binder.bind(info.parse_result, info.file_path, arena.allocator)
	}

	// 5. Build import edges + topo sort
	modules.build_import_edges(&graph)
	graph_diagnostics := make([dynamic]core.Diagnostic, 0, 8, arena.allocator)
	modules.topological_sort(&graph, &graph_diagnostics)

	// Report module graph diagnostics (e.g., cycle warnings)
	for d in graph_diagnostics {
		core.diagnostic_print(d)
	}

	// 6. Init resolution context + virtual module registry
	res_ctx := modules.init_resolution_context(&registry, arena.allocator)
	vreg := checker.init_virtual_registry(&registry)

	// 6b. Wire package cache for third-party import resolution
	pkg_cache, cache_err := platform.init_cache(arena.allocator)
	if cache_err == nil {
		res_ctx.bridge = bridge
		res_ctx.cache = &pkg_cache
		res_ctx.parsed_packages = make(map[string]modules.Module_Exports, 16, arena.allocator)
	}

	// 7. For each module in topo order: resolve → flow → check → export
	error_count := parse_errors
	for name in graph.topo_order {
		info, ok := graph.modules[name]
		if !ok || info.parse_result == nil { continue }

		// Read source for inline suppression
		mod_source, _ := os.read_entire_file(info.file_path, arena.allocator)
		mod_lines := strings.split(string(mod_source), "\n")

		// Report binder diagnostics
		for d in info.bind_result.diagnostics {
			if !should_emit_at_level(d.code, level) { continue }
			if is_line_suppressed(d.code, d.location.line, mod_lines) { continue }
			core.diagnostic_print(d)
			if d.severity == .Error { error_count += 1 }
		}

		// a. Resolve imports
		import_types := modules.resolve_imports(info, &res_ctx, &vreg)

		// b. Flow analysis
		flow_result := flow.analyze(info.parse_result, &info.bind_result, info.file_path, arena.allocator)
		for d in flow_result.diagnostics {
			if !should_emit_at_level(d.code, level) { continue }
			if is_line_suppressed(d.code, d.location.line, mod_lines) { continue }
			core.diagnostic_print(d)
			if d.severity == .Error { error_count += 1 }
		}

		// c. Type check with imports
		check_result := checker.check_with_imports(
			info.parse_result, &info.bind_result, &flow_result,
			info.file_path, &registry, &builtins, import_types, arena.allocator)
		for d in check_result.diagnostics {
			if !should_emit_at_level(d.code, level) { continue }
			if is_line_suppressed(d.code, d.location.line, mod_lines) { continue }
			core.diagnostic_print(d)
			if d.severity == .Error { error_count += 1 }
		}

		// d. Concurrency analysis (reuse already-read source)
		conc_source := string(mod_source)
		conc_diagnostics := concurrency.analyze_concurrency(
			info.parse_result, &info.bind_result, conc_source, info.file_path, arena.allocator)
		for d in conc_diagnostics {
			if !should_emit_at_level(d.code, level) { continue }
			if is_line_suppressed(d.code, d.location.line, mod_lines) { continue }
			core.diagnostic_print(d)
			if d.severity == .Error { error_count += 1 }
		}

		// e. Collect exports
		modules.collect_exports(info, &check_result, &res_ctx)

		// f. Print summary
		fmt.printfln("  checked %s (%d stmts, %d symbols, %d scopes, %d types)",
			info.file_path, len(info.parse_result.body),
			len(info.bind_result.symbols), len(info.bind_result.scopes),
			len(registry.types))
	}

	if error_count > 0 {
		fmt.eprintfln("mimir: %d error(s) in %d file(s)", error_count, len(files))
	} else {
		fmt.printfln("mimir: successfully checked %d file(s)", len(files))
	}
	return error_count
}

cmd_run :: proc(args: []string) {
	config := platform.Run_Config{}

	// Parse flags and find script path
	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--python" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir run: --python requires a version argument")
				os.exit(1)
			}
			config.python_version = args[i + 1]
			i += 2
		} else if arg == "--check" {
			config.check_first = true
			i += 1
		} else if arg == "--no-deps" {
			config.skip_deps = true
			i += 1
		} else if arg == "--" {
			// Everything after -- goes to the script
			if i + 1 < len(args) {
				config.script_args = args[i + 1:]
			}
			break
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintfln("mimir run: unknown flag '%s'", arg)
			fmt.eprintln("Usage: mimir run [--python <ver>] [--check] [--no-deps] <script> [-- args...]")
			os.exit(1)
		} else {
			// Script path
			config.script = arg
			i += 1
			// Check for -- after script
			if i < len(args) && args[i] == "--" {
				if i + 1 < len(args) {
					config.script_args = args[i + 1:]
				}
			}
			break
		}
	}

	if config.script == "" {
		fmt.eprintln("mimir run: no script specified")
		fmt.eprintln("Usage: mimir run [--python <ver>] [--check] [--no-deps] <script> [-- args...]")
		os.exit(1)
	}

	// Run with arena allocator
	arena: core.Analysis_Arena
	arena_err := core.arena_init(&arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize arena")
		os.exit(1)
	}

	// --check: run type checker on script before executing
	if config.check_first {
		bridge, bridge_err := parser.bridge_start()
		if bridge_err != nil {
			switch e in bridge_err {
			case parser.Bridge_Error:
				fmt.eprintfln("mimir: %s", e.msg)
			case parser.Syntax_Error:
				fmt.eprintfln("mimir: %s", e.msg)
			}
			os.exit(1)
		}
		check_errors := cmd_check_single(config.script, &bridge, &arena)
		parser.bridge_stop(&bridge)
		if check_errors > 0 {
			os.exit(1)
		}
	}

	exit_code := platform.run(config, arena.allocator)
	core.arena_destroy(&arena)
	os.exit(exit_code)
}

cmd_serve :: proc(args: []string) {
	config := platform.Serve_Config{
		port = 0,    // 0 = not set (use script default)
		host = "",   // "" = not set (use script default)
	}

	check_only := false

	// Parse flags
	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--port" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir serve: --port requires a number")
				os.exit(1)
			}
			port_val := 0
			for c in args[i + 1] {
				if c < '0' || c > '9' {
					fmt.eprintfln("mimir serve: invalid port '%s'", args[i + 1])
					os.exit(1)
				}
				port_val = port_val * 10 + int(c - '0')
			}
			config.port = port_val
			i += 2
		} else if arg == "--host" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir serve: --host requires an address")
				os.exit(1)
			}
			config.host = args[i + 1]
			i += 2
		} else if arg == "--python" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir serve: --python requires a version argument")
				os.exit(1)
			}
			config.python_version = args[i + 1]
			i += 2
		} else if arg == "--check" {
			check_only = true
			i += 1
		} else if arg == "--no-deps" {
			config.skip_deps = true
			i += 1
		} else if arg == "--static" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir serve: --static requires a directory path")
				os.exit(1)
			}
			config.static_dir = args[i + 1]
			i += 2
		} else if arg == "--tls-cert" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir serve: --tls-cert requires a file path")
				os.exit(1)
			}
			config.tls_cert = args[i + 1]
			i += 2
		} else if arg == "--tls-key" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir serve: --tls-key requires a file path")
				os.exit(1)
			}
			config.tls_key = args[i + 1]
			i += 2
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintfln("mimir serve: unknown flag '%s'", arg)
			fmt.eprintln("Usage: mimir serve [--port N] [--host H] [--static dir] [--tls-cert F --tls-key F] [--check] <script>")
			os.exit(1)
		} else {
			config.script = arg
			i += 1
			break
		}
	}

	if config.script == "" {
		fmt.eprintln("mimir serve: no script specified")
		fmt.eprintln("Usage: mimir serve [--port N] [--host H] [--static dir] [--tls-cert F --tls-key F] [--check] <script>")
		os.exit(1)
	}

	// Always type-check before serving
	arena: core.Analysis_Arena
	arena_err := core.arena_init(&arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize arena")
		os.exit(1)
	}

	bridge, bridge_err := parser.bridge_start()
	if bridge_err != nil {
		switch e in bridge_err {
		case parser.Bridge_Error:
			fmt.eprintfln("mimir: %s", e.msg)
		case parser.Syntax_Error:
			fmt.eprintfln("mimir: %s", e.msg)
		}
		os.exit(1)
	}

	fmt.printfln("  mimir: type checking %s...", config.script)
	check_errors := cmd_check_single(config.script, &bridge, &arena)
	parser.bridge_stop(&bridge)

	if check_errors > 0 {
		fmt.eprintfln("  mimir: %d error(s) found", check_errors)
		os.exit(1)
	}
	fmt.println("  mimir: ok (0 errors)")

	if check_only {
		core.arena_destroy(&arena)
		return
	}

	// Serve
	exit_code := platform.serve(config, arena.allocator)
	core.arena_destroy(&arena)
	os.exit(exit_code)
}

cmd_add :: proc(args: []string) {
	if len(args) == 0 {
		fmt.eprintln("mimir add: no packages specified")
		fmt.eprintln("Usage: mimir add <package> [package...]")
		os.exit(1)
	}

	arena: core.Analysis_Arena
	arena_err := core.arena_init(&arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize arena")
		os.exit(1)
	}
	defer core.arena_destroy(&arena)
	allocator := arena.allocator

	// Find or create mimir.toml
	cwd, cwd_err := os.get_working_directory(allocator)
	if cwd_err != nil {
		cwd = "."
	}
	config_path, config_found := platform.find_config(cwd, allocator)

	config: platform.Project_Config
	if config_found {
		cfg, read_err := platform.read_config(config_path, allocator)
		if read_err != nil {
			fmt.eprintfln("mimir add: %s", platform.error_msg(read_err))
			os.exit(1)
		}
		config = cfg
	} else {
		config = platform.default_config(cwd, allocator)
		config_path = config.file_path
		fmt.printfln("  creating %s", config_path)
	}

	// Add each package
	for arg in args {
		dep := platform.parse_dep_spec(arg, allocator)
		platform.add_dependency(&config, dep.name, dep.constraint, allocator)
		fmt.printfln("  added %s", dep.raw)
	}

	// Write mimir.toml
	write_err := platform.write_config(&config, config_path, allocator)
	if write_err != nil {
		fmt.eprintfln("mimir add: %s", platform.error_msg(write_err))
		os.exit(1)
	}

	// Lock
	python, py_ok := platform.find_python("", allocator)
	if !py_ok {
		fmt.eprintln("mimir add: python3 not found on PATH")
		os.exit(1)
	}

	if !platform.detect_pip(python, allocator) {
		fmt.eprintfln("mimir add: pip not available for '%s'", python)
		os.exit(1)
	}

	fmt.println("  resolving dependencies...")
	locked, resolve_err := platform.resolve_auto(python, config.dependencies[:], allocator)
	if resolve_err != nil {
		fmt.eprintfln("mimir add: %s", platform.error_msg(resolve_err))
		os.exit(1)
	}

	lf := platform.Lockfile{
		packages = make([dynamic]platform.Locked_Package, len(locked), allocator),
	}
	copy(lf.packages[:], locked)

	lock_path := platform.lockfile_path(config_path, allocator)
	lf_write_err := platform.write_lockfile(&lf, lock_path, allocator)
	if lf_write_err != nil {
		fmt.eprintfln("mimir add: %s", platform.error_msg(lf_write_err))
		os.exit(1)
	}
	fmt.printfln("  wrote %s (%d packages)", lock_path, len(lf.packages))

	// Install
	cache, cache_err := platform.init_cache(allocator)
	if cache_err != nil {
		fmt.eprintfln("mimir add: %s", platform.error_msg(cache_err))
		os.exit(1)
	}

	install_err := platform.install_from_lockfile(python, &lf, &cache, allocator)
	if install_err != nil {
		fmt.eprintfln("mimir add: %s", platform.error_msg(install_err))
		os.exit(1)
	}

	// Generate import map
	im := platform.generate_import_map(&lf, &cache, allocator)
	project_dir := platform.parent_dir(config_path)
	im_err := platform.write_import_map(&im, project_dir, allocator)
	if im_err == nil && len(im.packages) > 0 {
		fmt.printfln("  wrote .mimir/import_map.json (%d packages)", len(im.packages))
	}
}

cmd_lock :: proc(args: []string) {
	arena: core.Analysis_Arena
	arena_err := core.arena_init(&arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize arena")
		os.exit(1)
	}
	defer core.arena_destroy(&arena)
	allocator := arena.allocator

	// Find mimir.toml
	cwd, cwd_err := os.get_working_directory(allocator)
	if cwd_err != nil {
		cwd = "."
	}
	config_path, config_found := platform.find_config(cwd, allocator)
	if !config_found {
		fmt.eprintln("mimir lock: no mimir.toml found")
		fmt.eprintln("  run 'mimir add <package>' to create one")
		os.exit(1)
	}

	config, read_err := platform.read_config(config_path, allocator)
	if read_err != nil {
		fmt.eprintfln("mimir lock: %s", platform.error_msg(read_err))
		os.exit(1)
	}

	if len(config.dependencies) == 0 {
		fmt.println("  no dependencies to resolve")
		// Write empty lockfile
		lf := platform.Lockfile{
			packages = make([dynamic]platform.Locked_Package, 0, allocator),
		}
		lock_path := platform.lockfile_path(config_path, allocator)
		platform.write_lockfile(&lf, lock_path, allocator)
		fmt.printfln("  wrote %s (0 packages)", lock_path)
		return
	}

	python, py_ok := platform.find_python("", allocator)
	if !py_ok {
		fmt.eprintln("mimir lock: python3 not found on PATH")
		os.exit(1)
	}

	if !platform.detect_pip(python, allocator) {
		fmt.eprintfln("mimir lock: pip not available for '%s'", python)
		os.exit(1)
	}

	fmt.println("  resolving dependencies...")
	locked, resolve_err := platform.resolve_auto(python, config.dependencies[:], allocator)
	if resolve_err != nil {
		fmt.eprintfln("mimir lock: %s", platform.error_msg(resolve_err))
		os.exit(1)
	}

	lf := platform.Lockfile{
		packages = make([dynamic]platform.Locked_Package, len(locked), allocator),
	}
	copy(lf.packages[:], locked)

	// Generate import map if cache is available
	cache, cache_err := platform.init_cache(allocator)
	if cache_err == nil {
		im := platform.generate_import_map(&lf, &cache, allocator)
		project_dir := platform.parent_dir(config_path)
		im_err := platform.write_import_map(&im, project_dir, allocator)
		if im_err == nil {
			fmt.printfln("  wrote .mimir/import_map.json (%d packages)", len(im.packages))
		}
	}

	lock_path := platform.lockfile_path(config_path, allocator)
	lf_write_err := platform.write_lockfile(&lf, lock_path, allocator)
	if lf_write_err != nil {
		fmt.eprintfln("mimir lock: %s", platform.error_msg(lf_write_err))
		os.exit(1)
	}
	fmt.printfln("  wrote %s (%d packages)", lock_path, len(lf.packages))
}

cmd_install :: proc(args: []string) {
	arena: core.Analysis_Arena
	arena_err := core.arena_init(&arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize arena")
		os.exit(1)
	}
	defer core.arena_destroy(&arena)
	allocator := arena.allocator

	// Parse flags
	force := false
	for arg in args {
		if arg == "--force" {
			force = true
		}
	}

	// Find mimir.lock
	cwd, cwd_err := os.get_working_directory(allocator)
	if cwd_err != nil {
		cwd = "."
	}
	config_path, config_found := platform.find_config(cwd, allocator)
	if !config_found {
		fmt.eprintln("mimir install: no mimir.toml found")
		fmt.eprintln("  run 'mimir add <package>' to create one")
		os.exit(1)
	}

	lock_path := platform.lockfile_path(config_path, allocator)
	if !os.is_file(lock_path) {
		fmt.eprintln("mimir install: no mimir.lock found")
		fmt.eprintln("  run 'mimir lock' to generate a lockfile")
		os.exit(1)
	}

	lf, lf_err := platform.read_lockfile(lock_path, allocator)
	if lf_err != nil {
		fmt.eprintfln("mimir install: %s", platform.error_msg(lf_err))
		os.exit(1)
	}

	if len(lf.packages) == 0 {
		fmt.println("  no packages to install")
		return
	}

	python, py_ok := platform.find_python("", allocator)
	if !py_ok {
		fmt.eprintln("mimir install: python3 not found on PATH")
		os.exit(1)
	}

	if !platform.detect_pip(python, allocator) {
		fmt.eprintfln("mimir install: pip not available for '%s'", python)
		os.exit(1)
	}

	cache, cache_err := platform.init_cache(allocator)
	if cache_err != nil {
		fmt.eprintfln("mimir install: %s", platform.error_msg(cache_err))
		os.exit(1)
	}

	install_err := platform.install_from_lockfile(python, &lf, &cache, allocator, force)
	if install_err != nil {
		fmt.eprintfln("mimir install: %s", platform.error_msg(install_err))
		os.exit(1)
	}

	// Generate import map after install
	im := platform.generate_import_map(&lf, &cache, allocator)
	project_dir := platform.parent_dir(config_path)
	im_err := platform.write_import_map(&im, project_dir, allocator)
	if im_err == nil && len(im.packages) > 0 {
		fmt.printfln("  wrote .mimir/import_map.json (%d packages)", len(im.packages))
	}

	// Update lockfile with content hashes from install
	platform.write_lockfile(&lf, lock_path, allocator)
}

cmd_test :: proc(args: []string) {
	config := platform.Test_Config{
		target = ".",
	}

	// Parse flags
	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "-k" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir test: -k requires a pattern argument")
				os.exit(1)
			}
			config.filter = args[i + 1]
			i += 2
		} else if arg == "--check" {
			config.check_first = true
			i += 1
		} else if arg == "-v" || arg == "--verbose" {
			config.verbose = true
			i += 1
		} else if arg == "--coverage" || arg == "--cov" {
			config.coverage = true
			i += 1
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintfln("mimir test: unknown flag '%s'", arg)
			fmt.eprintln("Usage: mimir test [-k <pattern>] [--check] [--coverage] [-v] [path]")
			os.exit(1)
		} else {
			config.target = arg
			i += 1
		}
	}

	arena: core.Analysis_Arena
	arena_err := core.arena_init(&arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize arena")
		os.exit(1)
	}
	defer core.arena_destroy(&arena)

	// --check: type-check test files before running
	if config.check_first {
		test_files, discover_err := platform.discover_test_files(config.target, arena.allocator)
		if discover_err != nil {
			fmt.eprintfln("mimir test: %s", platform.error_msg(discover_err))
			os.exit(1)
		}

		if len(test_files) > 0 {
			bridge, bridge_err := parser.bridge_start()
			if bridge_err != nil {
				switch e in bridge_err {
				case parser.Bridge_Error:
					fmt.eprintfln("mimir: %s", e.msg)
				case parser.Syntax_Error:
					fmt.eprintfln("mimir: %s", e.msg)
				}
				os.exit(1)
			}

			total_errors := 0
			for file in test_files {
				total_errors += cmd_check_single(file, &bridge, &arena)
			}
			parser.bridge_stop(&bridge)

			if total_errors > 0 {
				os.exit(1)
			}
		}
	}

	// Run tests
	summary, run_err := platform.run_tests(config, arena.allocator)
	if run_err != nil {
		fmt.eprintfln("mimir test: %s", platform.error_msg(run_err))
		os.exit(1)
	}

	if len(summary.results) == 0 {
		fmt.println("mimir test: no tests found")
		return
	}

	platform.print_results(&summary, config.verbose)

	// Print coverage report if available
	if len(summary.coverage_report) > 0 {
		fmt.println()
		fmt.println("=== Coverage Report ===")
		fmt.print(summary.coverage_report)
	}

	if summary.failed > 0 || summary.errors > 0 {
		os.exit(1)
	}
}

cmd_lint :: proc(args: []string) {
	config := lint.default_config()

	// Parse flags
	target := "."
	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--ignore" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir lint: --ignore requires a code list (e.g. L001,C002)")
				os.exit(1)
			}
			config.ignore = lint.parse_code_list(args[i + 1])
			i += 2
		} else if arg == "--select" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir lint: --select requires a code list (e.g. L001,L002)")
				os.exit(1)
			}
			config.select_only = lint.parse_code_list(args[i + 1])
			i += 2
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintfln("mimir lint: unknown flag '%s'", arg)
			fmt.eprintln("Usage: mimir lint [--ignore <codes>] [--select <codes>] [path]")
			os.exit(1)
		} else {
			target = arg
			i += 1
		}
	}

	p: Pipeline; ok := pipeline_start("lint", target, &p)
	if !ok { return }
	defer pipeline_stop(&p)

	total_warnings := 0
	files_with_warnings := 0

	for file in p.files {
		source_data, read_err := os.read_entire_file(file, p.arena.allocator)
		if read_err != nil {
			fmt.eprintfln("mimir lint: cannot read '%s': %v", file, read_err)
			continue
		}
		source := string(source_data)

		module := pipeline_parse_file(&p, "lint", file)
		if module == nil { continue }

		bind_result := binder.bind(module, file, p.arena.allocator)
		diagnostics := lint.lint_file(module, &bind_result, source, file, &config, p.arena.allocator)

		if len(diagnostics) > 0 {
			files_with_warnings += 1
			total_warnings += len(diagnostics)
			for d in diagnostics { core.diagnostic_print(d) }
		}
	}

	if total_warnings > 0 {
		fmt.printfln("mimir lint: %d warning(s) in %d file(s)", total_warnings, files_with_warnings)
		os.exit(1)
	} else {
		fmt.printfln("mimir lint: %d file(s) clean", len(p.files))
	}
}

cmd_perf :: proc(args: []string) {
	config := perf.default_config()

	// Parse flags
	target := "."
	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--ignore" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir perf: --ignore requires a code list (e.g. PERF001,PERF003)")
				os.exit(1)
			}
			config.ignore = perf.parse_code_list(args[i + 1])
			i += 2
		} else if arg == "--select" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir perf: --select requires a code list (e.g. PERF001,PERF002)")
				os.exit(1)
			}
			config.select_only = perf.parse_code_list(args[i + 1])
			i += 2
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintfln("mimir perf: unknown flag '%s'", arg)
			fmt.eprintln("Usage: mimir perf [--ignore <codes>] [--select <codes>] [path]")
			os.exit(1)
		} else {
			target = arg
			i += 1
		}
	}

	p: Pipeline; ok := pipeline_start("perf", target, &p)
	if !ok { return }
	defer pipeline_stop(&p)

	total_issues := 0
	files_with_issues := 0

	for file in p.files {
		source_data, read_err := os.read_entire_file(file, p.arena.allocator)
		if read_err != nil {
			fmt.eprintfln("mimir perf: cannot read '%s': %v", file, read_err)
			continue
		}
		source := string(source_data)

		module := pipeline_parse_file(&p, "perf", file)
		if module == nil { continue }

		bind_result := binder.bind(module, file, p.arena.allocator)
		diagnostics := perf.analyze_performance(module, &bind_result, source, file, &config, p.arena.allocator)

		if len(diagnostics) > 0 {
			files_with_issues += 1
			total_issues += len(diagnostics)
			for d in diagnostics { core.diagnostic_print(d) }
		}
	}

	if total_issues > 0 {
		fmt.printfln("mimir perf: %d performance issue(s) in %d file(s)", total_issues, files_with_issues)
		os.exit(1)
	} else {
		fmt.printfln("mimir perf: %d file(s) clean", len(p.files))
	}
}

cmd_audit :: proc(args: []string) {
	config := security.default_config()

	// Parse flags
	target := "."
	verbose := false
	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--ignore" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir audit: --ignore requires a code list (e.g. SEC001,SEC003)")
				os.exit(1)
			}
			config.ignore = security.parse_code_list(args[i + 1])
			i += 2
		} else if arg == "--select" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir audit: --select requires a code list (e.g. SEC001,SEC002)")
				os.exit(1)
			}
			config.select_only = security.parse_code_list(args[i + 1])
			i += 2
		} else if arg == "-v" || arg == "--verbose" {
			verbose = true
			i += 1
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintfln("mimir audit: unknown flag '%s'", arg)
			fmt.eprintln("Usage: mimir audit [--ignore <codes>] [--select <codes>] [-v] [path]")
			os.exit(1)
		} else {
			target = arg
			i += 1
		}
	}

	p: Pipeline; ok := pipeline_start("audit", target, &p)
	if !ok { return }
	defer pipeline_stop(&p)

	total_issues := 0
	files_with_issues := 0

	for file in p.files {
		if verbose {
			fmt.printfln("  scanning %s", file)
		}

		// Read source
		source_data, read_err := os.read_entire_file(file, p.arena.allocator)
		if read_err != nil {
			fmt.eprintfln("mimir audit: cannot read '%s': %v", file, read_err)
			continue
		}
		source := string(source_data)

		module := pipeline_parse_file(&p, "audit", file)
		if module == nil { continue }

		// Bind (needed for import resolution)
		bind_result := binder.bind(module, file, p.arena.allocator)

		// Flow analysis (needed for taint tracking)
		flow_result := flow.analyze(module, &bind_result, file, p.arena.allocator)

		// Security scan (with taint analysis via flow_result)
		diagnostics := security.scan_file(module, &bind_result, source, file, &config, p.arena.allocator, &flow_result)

		if len(diagnostics) > 0 {
			files_with_issues += 1
			total_issues += len(diagnostics)
			for d in diagnostics {
				core.diagnostic_print(d)
			}
		}
	}

	if total_issues > 0 {
		fmt.printfln("mimir audit: %d security issue(s) in %d file(s)", total_issues, files_with_issues)
		os.exit(1)
	} else {
		fmt.printfln("mimir audit: %d file(s) clean", len(p.files))
	}
}

cmd_remove :: proc(args: []string) {
	if len(args) == 0 {
		fmt.eprintln("mimir remove: no packages specified")
		fmt.eprintln("Usage: mimir remove <package> [package...]")
		os.exit(1)
	}

	arena: core.Analysis_Arena
	arena_err := core.arena_init(&arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize arena")
		os.exit(1)
	}
	defer core.arena_destroy(&arena)
	allocator := arena.allocator

	// Find mimir.toml
	cwd, cwd_err := os.get_working_directory(allocator)
	if cwd_err != nil {
		cwd = "."
	}
	config_path, config_found := platform.find_config(cwd, allocator)
	if !config_found {
		fmt.eprintln("mimir remove: no mimir.toml found")
		os.exit(1)
	}

	config, read_err := platform.read_config(config_path, allocator)
	if read_err != nil {
		fmt.eprintfln("mimir remove: %s", platform.error_msg(read_err))
		os.exit(1)
	}

	// Remove each package
	any_removed := false
	for arg in args {
		name := strings.to_lower(arg, allocator)
		if platform.remove_dependency(&config, name) {
			fmt.printfln("  removed %s", name)
			any_removed = true
		} else {
			fmt.eprintfln("  '%s' not found in dependencies", name)
		}
	}

	if !any_removed {
		return
	}

	// Write updated mimir.toml
	write_err := platform.write_config(&config, config_path, allocator)
	if write_err != nil {
		fmt.eprintfln("mimir remove: %s", platform.error_msg(write_err))
		os.exit(1)
	}

	// Re-resolve and re-lock
	lock_path := platform.lockfile_path(config_path, allocator)
	if len(config.dependencies) == 0 {
		// Write empty lockfile
		lf := platform.Lockfile{
			packages = make([dynamic]platform.Locked_Package, 0, allocator),
		}
		platform.write_lockfile(&lf, lock_path, allocator)
		fmt.printfln("  wrote %s (0 packages)", lock_path)
		return
	}

	python, py_ok := platform.find_python("", allocator)
	if !py_ok {
		fmt.eprintln("mimir remove: python3 not found on PATH")
		os.exit(1)
	}

	if !platform.detect_pip(python, allocator) {
		fmt.eprintfln("mimir remove: pip not available for '%s'", python)
		os.exit(1)
	}

	fmt.println("  resolving dependencies...")
	locked, resolve_err := platform.resolve_auto(python, config.dependencies[:], allocator)
	if resolve_err != nil {
		fmt.eprintfln("mimir remove: %s", platform.error_msg(resolve_err))
		os.exit(1)
	}

	lf := platform.Lockfile{
		packages = make([dynamic]platform.Locked_Package, len(locked), allocator),
	}
	copy(lf.packages[:], locked)

	lf_write_err := platform.write_lockfile(&lf, lock_path, allocator)
	if lf_write_err != nil {
		fmt.eprintfln("mimir remove: %s", platform.error_msg(lf_write_err))
		os.exit(1)
	}
	fmt.printfln("  wrote %s (%d packages)", lock_path, len(lf.packages))

	// Regenerate import map after remove
	cache, cache_err := platform.init_cache(allocator)
	if cache_err == nil {
		im := platform.generate_import_map(&lf, &cache, allocator)
		project_dir := platform.parent_dir(config_path)
		platform.write_import_map(&im, project_dir, allocator)
	}
}

cmd_update :: proc(args: []string) {
	arena: core.Analysis_Arena
	arena_err := core.arena_init(&arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize arena")
		os.exit(1)
	}
	defer core.arena_destroy(&arena)
	allocator := arena.allocator

	// Find mimir.toml
	cwd, cwd_err := os.get_working_directory(allocator)
	if cwd_err != nil {
		cwd = "."
	}
	config_path, config_found := platform.find_config(cwd, allocator)
	if !config_found {
		fmt.eprintln("mimir update: no mimir.toml found")
		fmt.eprintln("  run 'mimir add <package>' to create one")
		os.exit(1)
	}

	config, read_err := platform.read_config(config_path, allocator)
	if read_err != nil {
		fmt.eprintfln("mimir update: %s", platform.error_msg(read_err))
		os.exit(1)
	}

	if len(config.dependencies) == 0 {
		fmt.println("  no dependencies to update")
		return
	}

	python, py_ok := platform.find_python("", allocator)
	if !py_ok {
		fmt.eprintln("mimir update: python3 not found on PATH")
		os.exit(1)
	}

	if !platform.detect_pip(python, allocator) {
		fmt.eprintfln("mimir update: pip not available for '%s'", python)
		os.exit(1)
	}

	// Re-resolve all dependencies (pip finds latest matching versions)
	fmt.println("  resolving dependencies...")
	locked, resolve_err := platform.resolve_auto(python, config.dependencies[:], allocator)
	if resolve_err != nil {
		fmt.eprintfln("mimir update: %s", platform.error_msg(resolve_err))
		os.exit(1)
	}

	lf := platform.Lockfile{
		packages = make([dynamic]platform.Locked_Package, len(locked), allocator),
	}
	copy(lf.packages[:], locked)

	lock_path := platform.lockfile_path(config_path, allocator)
	lf_write_err := platform.write_lockfile(&lf, lock_path, allocator)
	if lf_write_err != nil {
		fmt.eprintfln("mimir update: %s", platform.error_msg(lf_write_err))
		os.exit(1)
	}
	fmt.printfln("  wrote %s (%d packages)", lock_path, len(lf.packages))

	// Install
	cache, cache_err := platform.init_cache(allocator)
	if cache_err != nil {
		fmt.eprintfln("mimir update: %s", platform.error_msg(cache_err))
		os.exit(1)
	}

	install_err := platform.install_from_lockfile(python, &lf, &cache, allocator)
	if install_err != nil {
		fmt.eprintfln("mimir update: %s", platform.error_msg(install_err))
		os.exit(1)
	}

	// Generate import map
	im := platform.generate_import_map(&lf, &cache, allocator)
	project_dir := platform.parent_dir(config_path)
	im_err := platform.write_import_map(&im, project_dir, allocator)
	if im_err == nil && len(im.packages) > 0 {
		fmt.printfln("  wrote .mimir/import_map.json (%d packages)", len(im.packages))
	}
}

cmd_safety :: proc(args: []string) {
	config := safety.default_config()

	target := "."
	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--ignore" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir safety: --ignore requires a code list (e.g. SAF001,SAF003)")
				os.exit(1)
			}
			config.ignore = safety.parse_code_list(args[i + 1])
			i += 2
		} else if arg == "--select" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir safety: --select requires a code list (e.g. SAF001,SAF002)")
				os.exit(1)
			}
			config.select_only = safety.parse_code_list(args[i + 1])
			i += 2
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintfln("mimir safety: unknown flag '%s'", arg)
			fmt.eprintln("Usage: mimir safety [--ignore <codes>] [--select <codes>] [path]")
			os.exit(1)
		} else {
			target = arg
			i += 1
		}
	}

	p: Pipeline; ok := pipeline_start("safety", target, &p)
	if !ok { return }
	defer pipeline_stop(&p)

	total_issues := 0
	files_with_issues := 0

	for file in p.files {
		module := pipeline_parse_file(&p, "safety", file)
		if module == nil { continue }

		bind_result := binder.bind(module, file, p.arena.allocator)

		diagnostics := safety.analyze_safety(module, &bind_result, file, &config, p.arena.allocator)

		if len(diagnostics) > 0 {
			files_with_issues += 1
			total_issues += len(diagnostics)
			for d in diagnostics {
				core.diagnostic_print(d)
			}
		}
	}

	if total_issues > 0 {
		fmt.printfln("mimir safety: %d safety issue(s) in %d file(s)", total_issues, files_with_issues)
		os.exit(1)
	} else {
		fmt.printfln("mimir safety: %d file(s) clean", len(p.files))
	}
}

cmd_lsp :: proc() {
	bridge, bridge_err := parser.bridge_start()
	if bridge_err != nil {
		switch e in bridge_err {
		case parser.Bridge_Error:
			fmt.eprintfln("mimir: %s", e.msg)
		case parser.Syntax_Error:
			fmt.eprintfln("mimir: %s", e.msg)
		}
		os.exit(1)
	}
	defer parser.bridge_stop(&bridge)

	arena: core.Analysis_Arena
	arena_err := core.arena_init(&arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize arena")
		os.exit(1)
	}
	defer core.arena_destroy(&arena)

	server := lsp.init_server(&bridge, arena.allocator)
	lsp.run_server(&server)
}

cmd_repl :: proc(args: []string) {
	// Start parser bridge
	bridge, bridge_err := parser.bridge_start()
	if bridge_err != nil {
		switch e in bridge_err {
		case parser.Bridge_Error:
			fmt.eprintfln("mimir: %s", e.msg)
		case parser.Syntax_Error:
			fmt.eprintfln("mimir: %s", e.msg)
		}
		os.exit(1)
	}
	defer parser.bridge_stop(&bridge)

	// Initialize arena
	arena: core.Analysis_Arena
	arena_err := core.arena_init(&arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize arena")
		os.exit(1)
	}
	defer core.arena_destroy(&arena)

	// Initialize and run REPL
	state := platform.init_repl(&bridge, arena.allocator)
	platform.run_repl(&state)
}

cmd_python :: proc(args: []string) {
	if len(args) == 0 {
		fmt.eprintln("mimir python: no subcommand specified")
		fmt.eprintln("Usage: mimir python <install|list|remove> [args]")
		os.exit(1)
	}

	arena: core.Analysis_Arena
	arena_err := core.arena_init(&arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize arena")
		os.exit(1)
	}
	defer core.arena_destroy(&arena)
	allocator := arena.allocator

	switch args[0] {
	case "install":
		if len(args) < 2 {
			fmt.eprintln("mimir python install: no version specified")
			fmt.eprintln("Usage: mimir python install <version>")
			fmt.eprintln("  Examples: mimir python install 3.12")
			fmt.eprintln("            mimir python install 3.12.7")
			os.exit(1)
		}
		err := platform.install_python(args[1], allocator)
		if err != nil {
			fmt.eprintfln("mimir python install: %s", platform.error_msg(err))
			os.exit(1)
		}
	case "list":
		show_available := false
		for arg in args[1:] {
			if arg == "--available" || arg == "-a" {
				show_available = true
			}
		}
		if show_available {
			releases := platform.list_available_pythons()
			fmt.println("Available Python versions:")
			for r in releases {
				fmt.printfln("  %s", r.version)
			}
		} else {
			versions, err := platform.list_installed_pythons(allocator)
			if err != nil {
				fmt.eprintfln("mimir python list: %s", platform.error_msg(err))
				os.exit(1)
			}
			if len(versions) == 0 {
				fmt.println("No managed Python versions installed.")
				fmt.println("  Run 'mimir python install <version>' to install one.")
				fmt.println("  Run 'mimir python list --available' to see available versions.")
				return
			}
			fmt.println("Installed Python versions:")
			for v in versions {
				fmt.printfln("  %-10s %s", v.version, v.path)
			}
		}
	case "remove":
		if len(args) < 2 {
			fmt.eprintln("mimir python remove: no version specified")
			fmt.eprintln("Usage: mimir python remove <version>")
			os.exit(1)
		}
		err := platform.remove_python(args[1], allocator)
		if err != nil {
			fmt.eprintfln("mimir python remove: %s", platform.error_msg(err))
			os.exit(1)
		}
	case:
		fmt.eprintfln("mimir python: unknown subcommand '%s'", args[0])
		fmt.eprintln("Usage: mimir python <install|list|remove>")
		os.exit(1)
	}
}

cmd_build :: proc(args: []string) {
	arena: core.Analysis_Arena
	arena_err := core.arena_init(&arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize arena")
		os.exit(1)
	}
	defer core.arena_destroy(&arena)
	allocator := arena.allocator

	wheel_only := false
	sdist_only := false
	cwd, cwd_err := os.get_working_directory(allocator)
	if cwd_err != nil { cwd = "." }
	search_dir := cwd

	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--wheel" {
			wheel_only = true
			i += 1
		} else if arg == "--sdist" {
			sdist_only = true
			i += 1
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintfln("mimir build: unknown flag '%s'", arg)
			fmt.eprintln("Usage: mimir build [--wheel] [--sdist] [path]")
			os.exit(1)
		} else {
			search_dir = arg
			i += 1
		}
	}

	config_path, config_found := platform.find_config(search_dir, allocator)
	if !config_found {
		fmt.eprintln("mimir build: no mimir.toml found")
		fmt.eprintln("  create one with 'mimir add <package>' or manually")
		os.exit(1)
	}

	cfg, cfg_err := platform.read_build_config(config_path, allocator)
	if cfg_err != nil {
		fmt.eprintfln("mimir build: %s", platform.error_msg(cfg_err))
		os.exit(1)
	}

	val_err := platform.validate_build_config(&cfg)
	if val_err != nil {
		fmt.eprintfln("mimir build: %s", platform.error_msg(val_err))
		os.exit(1)
	}

	sources, src_err := platform.discover_sources(cfg.project_dir, allocator)
	if src_err != nil {
		fmt.eprintfln("mimir build: %s", platform.error_msg(src_err))
		os.exit(1)
	}

	fmt.printfln("mimir build: %s %s (%d files, %d packages)",
		cfg.name, cfg.version, len(sources.files), len(sources.packages))

	output_dir := strings.concatenate({cfg.project_dir, "/dist"}, allocator)

	if wheel_only && sdist_only {
		fmt.eprintln("mimir build: --wheel and --sdist are mutually exclusive")
		fmt.eprintln("  omit both flags to build wheel + sdist")
		os.exit(1)
	}

	if sdist_only {
		// sdist doesn't need Python
		sdist_path, sdist_err := platform.build_sdist(&cfg, &sources, output_dir, allocator)
		if sdist_err != nil {
			fmt.eprintfln("mimir build: %s", platform.error_msg(sdist_err))
			os.exit(1)
		}
		fmt.printfln("  built %s", sdist_path)
	} else {
		// Wheel needs Python for RECORD hash generation
		python, py_ok := platform.find_managed_python("", allocator)
		if !py_ok {
			python, py_ok = platform.find_python("", allocator)
		}
		if !py_ok {
			fmt.eprintln("mimir build: python3 not found (needed for RECORD generation)")
			os.exit(1)
		}

		if wheel_only {
			whl_path, whl_err := platform.build_wheel(&cfg, &sources, python, output_dir, allocator)
			if whl_err != nil {
				fmt.eprintfln("mimir build: %s", platform.error_msg(whl_err))
				os.exit(1)
			}
			fmt.printfln("  built %s", whl_path)
		} else {
			err := platform.build_all(&cfg, &sources, python, output_dir, allocator)
			if err != nil {
				fmt.eprintfln("mimir build: %s", platform.error_msg(err))
				os.exit(1)
			}
		}
	}
}

cmd_publish :: proc(args: []string) {
	arena: core.Analysis_Arena
	arena_err := core.arena_init(&arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize arena")
		os.exit(1)
	}
	defer core.arena_destroy(&arena)
	allocator := arena.allocator

	index_url := ""
	cwd, cwd_err := os.get_working_directory(allocator)
	if cwd_err != nil { cwd = "." }
	search_dir := cwd

	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--index" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir publish: --index requires a URL")
				os.exit(1)
			}
			index_url = args[i + 1]
			i += 2
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintfln("mimir publish: unknown flag '%s'", arg)
			fmt.eprintln("Usage: mimir publish [--index <url>] [path]")
			os.exit(1)
		} else {
			search_dir = arg
			i += 1
		}
	}

	// Find credentials
	pub_cfg, cred_err := platform.find_credentials(allocator)
	if cred_err != nil {
		fmt.eprintfln("mimir publish: %s", platform.error_msg(cred_err))
		os.exit(1)
	}
	if index_url != "" {
		pub_cfg.index_url = index_url
	}

	// Find project directory
	config_path, config_found := platform.find_config(search_dir, allocator)
	project_dir := search_dir
	if config_found {
		project_dir = platform.parent_dir(config_path)
	}

	dist_dir := strings.concatenate({project_dir, "/dist"}, allocator)

	// Auto-build if dist/ doesn't exist
	if !os.is_directory(dist_dir) {
		if !config_found {
			fmt.eprintln("mimir publish: no dist/ directory and no mimir.toml found")
			fmt.eprintln("  run 'mimir build' first")
			os.exit(1)
		}

		fmt.println("  dist/ not found, building first...")
		cfg, cfg_err := platform.read_build_config(config_path, allocator)
		if cfg_err != nil {
			fmt.eprintfln("mimir publish: %s", platform.error_msg(cfg_err))
			os.exit(1)
		}
		val_err := platform.validate_build_config(&cfg)
		if val_err != nil {
			fmt.eprintfln("mimir publish: %s", platform.error_msg(val_err))
			os.exit(1)
		}
		sources, src_err := platform.discover_sources(cfg.project_dir, allocator)
		if src_err != nil {
			fmt.eprintfln("mimir publish: %s", platform.error_msg(src_err))
			os.exit(1)
		}
		python, py_ok := platform.find_managed_python("", allocator)
		if !py_ok {
			python, py_ok = platform.find_python("", allocator)
		}
		if !py_ok {
			fmt.eprintln("mimir publish: python3 not found (needed for building)")
			os.exit(1)
		}
		build_err := platform.build_all(&cfg, &sources, python, dist_dir, allocator)
		if build_err != nil {
			fmt.eprintfln("mimir publish: %s", platform.error_msg(build_err))
			os.exit(1)
		}
	}

	// Upload
	pub_err := platform.publish_dist(&pub_cfg, dist_dir, allocator)
	if pub_err != nil {
		fmt.eprintfln("mimir publish: %s", platform.error_msg(pub_err))
		os.exit(1)
	}

	fmt.println("mimir publish: done")
}

print_usage :: proc() {
	fmt.println("mimir — Python development platform")
	fmt.println()
	fmt.println("Usage: mimir <command> [options]")
	fmt.println()
	fmt.println("Commands:")
	fmt.println("  check <path>      Analyze Python source files")
	fmt.println("  format [path]     Format Python source files (default: \".\")")
	fmt.println("  audit [path]      Scan Python files for security vulnerabilities (default: \".\")")
	fmt.println("  lint [path]       Lint Python files for common issues (default: \".\")")
	fmt.println("  safety [path]     Detect Python safety issues (default: \".\")")
	fmt.println("  perf [path]       Detect Python performance anti-patterns (default: \".\")")
	fmt.println("  test [path]       Run tests (discovers test_*.py and *_test.py files)")
	fmt.println("  repl              Start type-aware interactive Python REPL")
	fmt.println("  lsp               Start LSP server for editor integration")
	fmt.println("  run <script>      Run a Python script with automatic dependency resolution")
	fmt.println("  serve <script>    Serve an HTTP app (mimir.http) with type checking")
	fmt.println("  build [path]      Build wheel + sdist package (output to dist/)")
	fmt.println("  publish [path]    Publish package to PyPI (builds if needed)")
	fmt.println("  python <cmd>      Manage Python versions (install, list, remove)")
	fmt.println("  add <packages>    Add dependencies to mimir.toml, lock, and install")
	fmt.println("  remove <packages> Remove dependencies from mimir.toml and re-lock")
	fmt.println("  update            Re-resolve all dependencies to latest matching versions")
	fmt.println("  lock              Resolve dependencies and generate mimir.lock")
	fmt.println("  install           Install dependencies from mimir.lock")
	fmt.println("  migrate [path]    Detect Python version migration opportunities")
	fmt.println("  import-config <f> Import mypy configuration to mimir.toml format")
	fmt.println("  stubs <path>      Generate .pyi stub files from type analysis")
	fmt.println("  generate-contracts <path>  Generate runtime type-checking decorators")
	fmt.println("  generate-tests <path>      Generate hypothesis test skeletons")
	fmt.println("  gpu [path]        Validate @gpu functions and extract compute graphs")
	fmt.println("  compile-gpu [path] Emit GPU compute shaders (--backend wgsl|msl|spirv|ptx|all)")
	fmt.println("  compile-wasm [path] Compile @wasm functions to WebAssembly (--format wat|wasm|all, -O, --wasi, --js)")
	fmt.println("  conform [path]    Run conformance tests (default: tests/conformance/)")
	fmt.println("  explain <code>    Show detailed explanation for a diagnostic code")
	fmt.println("  version           Print version")
	fmt.println("  help              Show this message")
}

// ==================== migrate command ====================

cmd_migrate :: proc(args: []string) {
	config := migration.default_config()

	target := "."
	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--from" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir migrate: --from requires a version (e.g. 3.8)")
				os.exit(1)
			}
			ver, ok := migration.parse_version(args[i + 1])
			if !ok {
				fmt.eprintfln("mimir migrate: invalid version '%s' (expected e.g. 3.8)", args[i + 1])
				os.exit(1)
			}
			config.from_version = ver
			i += 2
		} else if arg == "--to" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir migrate: --to requires a version (e.g. 3.12)")
				os.exit(1)
			}
			ver, ok := migration.parse_version(args[i + 1])
			if !ok {
				fmt.eprintfln("mimir migrate: invalid version '%s' (expected e.g. 3.12)", args[i + 1])
				os.exit(1)
			}
			config.to_version = ver
			i += 2
		} else if arg == "--ignore" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir migrate: --ignore requires a code list (e.g. MIG001,MIG003)")
				os.exit(1)
			}
			config.ignore = migration.parse_code_list(args[i + 1])
			i += 2
		} else if arg == "--select" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir migrate: --select requires a code list (e.g. MIG001,MIG002)")
				os.exit(1)
			}
			config.select_only = migration.parse_code_list(args[i + 1])
			i += 2
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintfln("mimir migrate: unknown flag '%s'", arg)
			fmt.eprintln("Usage: mimir migrate [--from <ver>] [--to <ver>] [--ignore <codes>] [--select <codes>] [path]")
			os.exit(1)
		} else {
			target = arg
			i += 1
		}
	}

	fmt.printfln("Scanning for migration opportunities (Python %d.%d → %d.%d)...\n",
		config.from_version.major, config.from_version.minor,
		config.to_version.major, config.to_version.minor)

	p: Pipeline; ok := pipeline_start("migrate", target, &p)
	if !ok { return }
	defer pipeline_stop(&p)

	total_issues := 0
	files_with_issues := 0
	// Count per rule
	rule_counts: [len(migration.ALL_RULES)]int

	for file in p.files {
		module := pipeline_parse_file(&p, "migrate", file)
		if module == nil { continue }

		bind_result := binder.bind(module, file, p.arena.allocator)

		diagnostics := migration.analyze_migration(module, &bind_result, file, &config, p.arena.allocator)

		if len(diagnostics) > 0 {
			files_with_issues += 1
			for d in diagnostics {
				core.diagnostic_print(d)
				total_issues += 1
				// Count by rule
				for idx := 0; idx < len(migration.ALL_RULES); idx += 1 {
					if migration.ALL_RULES[idx].code == d.code {
						rule_counts[idx] += 1
						break
					}
				}
			}
		}
	}

	// Summary
	fmt.println()
	if total_issues == 0 {
		fmt.printfln("No migration opportunities found (%d files scanned).", len(p.files))
	} else {
		fmt.println("Migration summary:")
		for idx := 0; idx < len(migration.ALL_RULES); idx += 1 {
			if rule_counts[idx] > 0 {
				fmt.printfln("  %s %-28s %d occurrences",
					migration.ALL_RULES[idx].code,
					migration.ALL_RULES[idx].name,
					rule_counts[idx])
			}
		}
		fmt.printfln("  Total: %d migration opportunities across %d files", total_issues, files_with_issues)
	}
}

// ==================== import-config command ====================

cmd_import_config :: proc(args: []string) {
	if len(args) == 0 {
		fmt.eprintln("mimir import-config: requires a config file path")
		fmt.eprintln("Usage: mimir import-config <mypy.ini|setup.cfg|pyproject.toml>")
		os.exit(1)
	}

	config_path := args[0]

	fmt.printfln("Reading %s...\n", config_path)

	result, ok := migration.import_mypy_config(config_path, context.temp_allocator)
	if !ok {
		fmt.eprintfln("mimir import-config: could not read '%s'", config_path)
		os.exit(1)
	}

	migration.print_import_result(&result)
}

// ==================== stubs command ====================

cmd_stubs :: proc(args: []string) {
	target := ""
	output_dir := ""

	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--output-dir" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir stubs: --output-dir requires a directory argument")
				os.exit(1)
			}
			output_dir = args[i + 1]
			i += 2
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintfln("mimir stubs: unknown flag '%s'", arg)
			fmt.eprintln("Usage: mimir stubs <path> [--output-dir <dir>]")
			os.exit(1)
		} else {
			target = arg
			i += 1
		}
	}

	if target == "" {
		fmt.eprintln("mimir stubs: no input path specified")
		fmt.eprintln("Usage: mimir stubs <path> [--output-dir <dir>]")
		os.exit(1)
	}

	p: Pipeline; ok := pipeline_start("stubs", target, &p)
	if !ok { return }
	defer pipeline_stop(&p)

	generated := 0
	for file in p.files {
		module := pipeline_parse_file(&p, "stubs", file)
		if module == nil { continue }

		bind_result := binder.bind(module, file, p.arena.allocator)
		flow_result := flow.analyze(module, &bind_result, file, p.arena.allocator)
		check_result := checker.check(module, &bind_result, &flow_result, file, p.arena.allocator)

		// Compute output path: foo.py → foo.pyi
		out_path := ""
		if output_dir != "" {
			base := file_basename(file)
			out_path = fmt.aprintf("%s/%si", output_dir, base, allocator = p.arena.allocator)
		} else {
			out_path = fmt.aprintf("%si", file, allocator = p.arena.allocator)
		}

		gen_err := codegen.generate_stubs(module, &bind_result, &check_result, out_path, p.arena.allocator)
		if gen_err != nil {
			#partial switch e in gen_err {
			case codegen.Error_Data:
				fmt.eprintfln("mimir stubs: %s", e.msg)
			}
		} else {
			fmt.printfln("  generated %s", out_path)
			generated += 1
		}
	}

	fmt.printfln("mimir stubs: generated %d stub file(s)", generated)
}

// ==================== generate-contracts command ====================

cmd_generate_contracts :: proc(args: []string) {
	target := ""
	output_dir := ""

	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--output-dir" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir generate-contracts: --output-dir requires a directory argument")
				os.exit(1)
			}
			output_dir = args[i + 1]
			i += 2
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintfln("mimir generate-contracts: unknown flag '%s'", arg)
			fmt.eprintln("Usage: mimir generate-contracts <path> [--output-dir <dir>]")
			os.exit(1)
		} else {
			target = arg
			i += 1
		}
	}

	if target == "" {
		fmt.eprintln("mimir generate-contracts: no input path specified")
		fmt.eprintln("Usage: mimir generate-contracts <path> [--output-dir <dir>]")
		os.exit(1)
	}

	p: Pipeline; ok := pipeline_start("generate-contracts", target, &p)
	if !ok { return }
	defer pipeline_stop(&p)

	generated := 0
	for file in p.files {
		module := pipeline_parse_file(&p, "generate-contracts", file)
		if module == nil { continue }

		bind_result := binder.bind(module, file, p.arena.allocator)
		flow_result := flow.analyze(module, &bind_result, file, p.arena.allocator)
		check_result := checker.check(module, &bind_result, &flow_result, file, p.arena.allocator)

		// Compute output path: foo.py → foo_contracts.py
		base := file_stem(file)
		out_path := ""
		if output_dir != "" {
			out_path = fmt.aprintf("%s/%s_contracts.py", output_dir, base, allocator = p.arena.allocator)
		} else {
			dir := file_dir(file)
			out_path = fmt.aprintf("%s%s_contracts.py", dir, base, allocator = p.arena.allocator)
		}

		gen_err := codegen.generate_contracts(module, &bind_result, &check_result, out_path, p.arena.allocator)
		if gen_err != nil {
			#partial switch e in gen_err {
			case codegen.Error_Data:
				fmt.eprintfln("mimir generate-contracts: %s", e.msg)
			}
		} else {
			fmt.printfln("  generated %s", out_path)
			generated += 1
		}
	}

	fmt.printfln("mimir generate-contracts: generated %d contract file(s)", generated)
}

// ==================== generate-tests command ====================

cmd_generate_tests :: proc(args: []string) {
	target := ""
	output_dir := ""

	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--output-dir" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir generate-tests: --output-dir requires a directory argument")
				os.exit(1)
			}
			output_dir = args[i + 1]
			i += 2
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintfln("mimir generate-tests: unknown flag '%s'", arg)
			fmt.eprintln("Usage: mimir generate-tests <path> [--output-dir <dir>]")
			os.exit(1)
		} else {
			target = arg
			i += 1
		}
	}

	if target == "" {
		fmt.eprintln("mimir generate-tests: no input path specified")
		fmt.eprintln("Usage: mimir generate-tests <path> [--output-dir <dir>]")
		os.exit(1)
	}

	p: Pipeline; ok := pipeline_start("generate-tests", target, &p)
	if !ok { return }
	defer pipeline_stop(&p)

	generated := 0
	for file in p.files {
		module := pipeline_parse_file(&p, "generate-tests", file)
		if module == nil { continue }

		bind_result := binder.bind(module, file, p.arena.allocator)
		flow_result := flow.analyze(module, &bind_result, file, p.arena.allocator)
		check_result := checker.check(module, &bind_result, &flow_result, file, p.arena.allocator)

		// Compute module name and output path
		mod_name := file_stem(file)
		out_path := ""
		if output_dir != "" {
			out_path = fmt.aprintf("%s/test_%s.py", output_dir, mod_name, allocator = p.arena.allocator)
		} else {
			dir := file_dir(file)
			out_path = fmt.aprintf("%stest_%s.py", dir, mod_name, allocator = p.arena.allocator)
		}

		gen_err := codegen.generate_tests(module, &bind_result, &check_result, mod_name, out_path, p.arena.allocator)
		if gen_err != nil {
			#partial switch e in gen_err {
			case codegen.Error_Data:
				fmt.eprintfln("mimir generate-tests: %s", e.msg)
			}
		} else {
			fmt.printfln("  generated %s", out_path)
			generated += 1
		}
	}

	fmt.printfln("mimir generate-tests: generated %d test file(s)", generated)
}

// ==================== GPU command ====================

cmd_gpu :: proc(args: []string) {
	config := gpu.default_gpu_config()

	target := "."
	verbose := false
	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--ignore" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir gpu: --ignore requires a code list (e.g. GPU001,GPU003)")
				os.exit(1)
			}
			config.ignore = gpu_parse_code_list(args[i + 1])
			i += 2
		} else if arg == "--select" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir gpu: --select requires a code list (e.g. GPU001,GPU002)")
				os.exit(1)
			}
			config.select_only = gpu_parse_code_list(args[i + 1])
			i += 2
		} else if arg == "-v" || arg == "--verbose" {
			verbose = true
			i += 1
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintfln("mimir gpu: unknown flag '%s'", arg)
			fmt.eprintln("Usage: mimir gpu [--ignore <codes>] [--select <codes>] [-v] [path]")
			os.exit(1)
		} else {
			target = arg
			i += 1
		}
	}

	p: Pipeline; ok := pipeline_start("gpu", target, &p)
	if !ok { return }
	defer pipeline_stop(&p)

	// Initialize GPU type context
	reg := checker.init_registry(p.arena.allocator)
	type_ctx := gpu.init_gpu_types(&reg, p.arena.allocator)

	total_errors := 0
	total_funcs := 0
	total_nodes := 0

	for file in p.files {
		module := pipeline_parse_file(&p, "gpu", file)
		if module == nil { continue }

		bind_result := binder.bind(module, file, p.arena.allocator)

		// GPU validation
		diagnostics, gpu_funcs := gpu.validate_file(module, &bind_result, &type_ctx, file, &config, p.arena.allocator)

		if len(gpu_funcs) > 0 {
			fmt.printfln("GPU analysis: %s", file)
			fmt.println()
		}

		// Print diagnostics
		if len(diagnostics) > 0 {
			total_errors += len(diagnostics)
			for d in diagnostics {
				core.diagnostic_print(d)
			}
		}

		// Extract and display compute graphs for valid functions
		for func in gpu_funcs {
			total_funcs += 1
			// Only extract graph if no errors for this function
			graph, graph_diags := gpu.extract_graph(func, &bind_result, &type_ctx, file, p.arena.allocator)
			total_nodes += len(graph.nodes)

			// Print graph-level diagnostics (shape mismatches, unsupported ops)
			if len(graph_diags) > 0 {
				total_errors += len(graph_diags)
				for d in graph_diags {
					core.diagnostic_print(d)
				}
			}

			// Summary line
			elem, mm, red, oth := gpu.count_ops(&graph)
			fmt.printfln("  @gpu %s (line %d)", func.name, int(func.loc.line))

			// Print param info
			for arg in func.args.args {
				if arg.annotation != nil {
					tid := gpu.resolve_gpu_annotation(arg.annotation, &type_ctx)
					if tid != checker.INVALID_TYPE {
						fmt.printfln("    %s: %s", arg.arg, checker.type_to_string(&reg, tid))
					}
				}
			}

			fmt.printfln("    Graph: %d nodes (%d elementwise, %d matmul, %d reduction)",
				len(graph.nodes), elem, mm, red)

			if verbose {
				gpu.print_graph(&graph)
			}

			// Output type from graph
			if len(graph.outputs) > 0 {
				out_node := gpu.get_node(&graph, graph.outputs[0])
				if out_node != nil && out_node.output_type != checker.INVALID_TYPE {
					fmt.printfln("    Output: %s", checker.type_to_string(&reg, out_node.output_type))
				}
			}
			fmt.println()
		}
	}

	if total_funcs > 0 {
		if total_errors > 0 {
			fmt.printfln("mimir gpu: %d @gpu function(s), %d error(s)", total_funcs, total_errors)
			os.exit(1)
		} else {
			fmt.printfln("mimir gpu: %d @gpu function(s), %d nodes, 0 errors", total_funcs, total_nodes)
		}
	} else {
		fmt.printfln("mimir gpu: no @gpu functions found in %d file(s)", len(p.files))
	}
}

gpu_parse_code_list :: proc(input: string) -> []string {
	if input == "" { return nil }
	parts := strings.split(input, ",")
	result := make([dynamic]string, 0, len(parts))
	for p in parts {
		trimmed := strings.trim_space(p)
		if trimmed != "" {
			append(&result, trimmed)
		}
	}
	return result[:]
}

// ==================== compile-gpu command ====================

cmd_compile_gpu :: proc(args: []string) {
	config := gpu.default_gpu_config()

	target := "."
	verbose := false
	backend_name := "wgsl"
	output_dir := ""
	emit_all := false
	fuse_flag := false
	plan_flag := false
	backward_flag := false

	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--backend" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir compile-gpu: --backend requires a value (wgsl|msl|spirv|ptx|all)")
				os.exit(1)
			}
			backend_name = args[i + 1]
			if backend_name == "all" {
				emit_all = true
			}
			i += 2
		} else if arg == "--output" || arg == "-o" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir compile-gpu: --output requires a directory path")
				os.exit(1)
			}
			output_dir = args[i + 1]
			i += 2
		} else if arg == "-v" || arg == "--verbose" {
			verbose = true
			i += 1
		} else if arg == "--fuse" {
			fuse_flag = true
			i += 1
		} else if arg == "--plan" {
			plan_flag = true
			i += 1
		} else if arg == "--backward" {
			backward_flag = true
			i += 1
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintfln("mimir compile-gpu: unknown flag '%s'", arg)
			fmt.eprintln("Usage: mimir compile-gpu [--backend <wgsl|msl|spirv|ptx|all>] [--output <dir>] [-v] [--fuse] [--plan] [--backward] [path]")
			os.exit(1)
		} else {
			target = arg
			i += 1
		}
	}

	// Validate backend
	backend: gpu.Emit_Backend
	if !emit_all {
		ok: bool
		backend, ok = gpu.parse_backend(backend_name)
		if !ok {
			fmt.eprintfln("mimir compile-gpu: unknown backend '%s'", backend_name)
			fmt.eprintln("Valid backends: wgsl, msl, spirv, ptx, all")
			os.exit(1)
		}
	}

	p: Pipeline; ok := pipeline_start("compile-gpu", target, &p)
	if !ok { return }
	defer pipeline_stop(&p)

	reg := checker.init_registry(p.arena.allocator)
	type_ctx := gpu.init_gpu_types(&reg, p.arena.allocator)

	total_kernels := 0

	backends_to_emit: [dynamic]gpu.Emit_Backend
	if emit_all {
		backends_to_emit = make([dynamic]gpu.Emit_Backend, 0, 4, p.arena.allocator)
		append(&backends_to_emit, gpu.Emit_Backend.WGSL)
		append(&backends_to_emit, gpu.Emit_Backend.MSL)
		append(&backends_to_emit, gpu.Emit_Backend.SPIRV)
		append(&backends_to_emit, gpu.Emit_Backend.PTX)
	} else {
		backends_to_emit = make([dynamic]gpu.Emit_Backend, 0, 1, p.arena.allocator)
		append(&backends_to_emit, backend)
	}

	for file in p.files {
		module := pipeline_parse_file(&p, "compile-gpu", file)
		if module == nil { continue }

		bind_result := binder.bind(module, file, p.arena.allocator)
		_, gpu_funcs := gpu.validate_file(module, &bind_result, &type_ctx, file, &config, p.arena.allocator)

		for func in gpu_funcs {
			graph, graph_diags2 := gpu.extract_graph(func, &bind_result, &type_ctx, file, p.arena.allocator)
			for d in graph_diags2 { core.diagnostic_print(d) }

			// Phase 27: Fusion
			if fuse_flag {
				fusion := gpu.fuse_kernels(&graph, p.arena.allocator)
				if verbose {
					gpu.print_fusion(&fusion)
				}

				// Memory plan (with fusion)
				if plan_flag {
					mem_plan := gpu.plan_memory(&graph, &fusion, &type_ctx, p.arena.allocator)
					gpu.print_memory_plan(&mem_plan)
				}

				// Build node→group map for subgraph extraction
				node_group_map := make(map[gpu.GPU_Node_ID]int, len(graph.nodes), p.arena.allocator)
				for &grp in fusion.groups {
					for nid in grp.node_ids {
						node_group_map[nid] = grp.id
					}
				}

				// Emit each fusion group as a separate kernel
				for group_idx in fusion.order {
					grp := &fusion.groups[group_idx]
					sub := gpu.extract_subgraph(&graph, grp, &node_group_map, p.arena.allocator)

					for be in backends_to_emit {
						data, is_binary := gpu.emit_kernel(&sub, &type_ctx, be, p.arena.allocator)
						if data == nil { continue }
						ext := gpu.backend_extension(be)
						emit_gpu_output(output_dir, fmt.tprintf("%s_%d", graph.func_name, grp.id), ext, data, is_binary, verbose, &graph, be)
						total_kernels += 1
					}
				}
			} else {
				// No fusion — emit single kernel (Phase 26 behavior)
				if plan_flag {
					mem_plan := gpu.plan_memory(&graph, nil, &type_ctx, p.arena.allocator)
					gpu.print_memory_plan(&mem_plan)
				}

				for be in backends_to_emit {
					data, is_binary := gpu.emit_kernel(&graph, &type_ctx, be, p.arena.allocator)
					if data == nil { continue }
					ext := gpu.backend_extension(be)
					emit_gpu_output(output_dir, graph.func_name, ext, data, is_binary, verbose, &graph, be)
					total_kernels += 1
				}
			}

			// Phase 27: Backward pass generation
			if backward_flag {
				backward := gpu.generate_backward(&graph, &type_ctx, p.arena.allocator)
				if verbose {
					fmt.printfln("  Backward: %d nodes (forward: %d)", len(backward.nodes), len(graph.nodes))
				}
				for be in backends_to_emit {
					data, is_binary := gpu.emit_kernel(&backward, &type_ctx, be, p.arena.allocator)
					if data == nil { continue }
					ext := gpu.backend_extension(be)
					emit_gpu_output(output_dir, backward.func_name, ext, data, is_binary, verbose, &backward, be)
					total_kernels += 1
				}
			}
		}
	}

	if total_kernels > 0 {
		fmt.printfln("mimir compile-gpu: emitted %d kernel(s)", total_kernels)
	} else {
		fmt.printfln("mimir compile-gpu: no @gpu functions found in %d file(s)", len(p.files))
	}
}

// Helper: emit GPU kernel output (file or stdout).
emit_gpu_output :: proc(
	output_dir: string,
	name: string,
	ext: string,
	data: []u8,
	is_binary: bool,
	verbose: bool,
	graph: ^gpu.Compute_Graph,
	be: gpu.Emit_Backend,
) {
	if output_dir != "" {
		out_path := fmt.tprintf("%s/%s.%s", output_dir, name, ext)
		write_err := os.write_entire_file(out_path, data)
		if write_err != nil {
			fmt.eprintfln("mimir compile-gpu: error writing '%s': %v", out_path, write_err)
			return
		}
		if verbose {
			fmt.printfln("  wrote %s (%d bytes)", out_path, len(data))
		}
	} else {
		if verbose {
			elem, mm, red, _ := gpu.count_ops(graph)
			fmt.printfln("// kernel_%s (%d nodes: %d elem, %d matmul, %d reduction) [%s]",
				name, len(graph.nodes), elem, mm, red, ext)
		}
		if is_binary {
			fmt.printfln("// SPIR-V binary: %d bytes", len(data))
		} else {
			text := string(data)
			fmt.print(text)
		}
		fmt.println()
	}
}

// ==================== compile-wasm command ====================

cmd_compile_wasm :: proc(args: []string) {
	config := wasm.default_wasm_config()

	target := "."
	verbose := false
	format_name := "wat"
	output_dir := ""
	emit_all := false
	optimize := false
	wasi_mode := false
	emit_js := false

	i := 0
	for i < len(args) {
		arg := args[i]
		if arg == "--format" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir compile-wasm: --format requires a value (wat|wasm|all)")
				os.exit(1)
			}
			format_name = args[i + 1]
			if format_name == "all" {
				emit_all = true
			}
			i += 2
		} else if arg == "--output" || arg == "-o" {
			if i + 1 >= len(args) {
				fmt.eprintln("mimir compile-wasm: --output requires a directory path")
				os.exit(1)
			}
			output_dir = args[i + 1]
			i += 2
		} else if arg == "-v" || arg == "--verbose" {
			verbose = true
			i += 1
		} else if arg == "--optimize" || arg == "-O" {
			optimize = true
			i += 1
		} else if arg == "--wasi" {
			wasi_mode = true
			i += 1
		} else if arg == "--js" {
			emit_js = true
			i += 1
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintfln("mimir compile-wasm: unknown flag '%s'", arg)
			fmt.eprintln("Usage: mimir compile-wasm [--format <wat|wasm|all>] [--output <dir>] [-v] [-O] [--wasi] [--js] [path]")
			os.exit(1)
		} else {
			target = arg
			i += 1
		}
	}

	// --js implies wasm binary output
	if emit_js && format_name == "wat" {
		format_name = "wasm"
	}

	// Validate format
	if !emit_all && format_name != "wat" && format_name != "wasm" {
		fmt.eprintfln("mimir compile-wasm: unknown format '%s'", format_name)
		fmt.eprintln("Valid formats: wat, wasm, all")
		os.exit(1)
	}

	p: Pipeline; ok := pipeline_start("compile-wasm", target, &p)
	if !ok { return }
	defer pipeline_stop(&p)

	type_ctx := wasm.init_wasm_types(p.arena.allocator)
	total_modules := 0
	has_errors := false

	for file in p.files {
		module := pipeline_parse_file(&p, "compile-wasm", file)
		if module == nil { continue }

		bind_result := binder.bind(module, file, p.arena.allocator)
		diags, wasm_funcs := wasm.validate_file(module, &bind_result, &type_ctx, file, &config, p.arena.allocator)

		// Print restriction diagnostics
		for d in diags {
			core.diagnostic_print(d)
			if d.severity == .Error { has_errors = true }
		}

		if has_errors || len(wasm_funcs) == 0 { continue }

		// Extract WASM module
		wasm_module := wasm.extract_wasm_module(module, wasm_funcs, &bind_result, &type_ctx, p.arena.allocator, wasi_mode)

		// Optimization pass
		if optimize {
			wasm.optimize_module(&wasm_module, p.arena.allocator)
		}

		if verbose {
			fmt.printfln("  %s: %d @wasm function(s), %d import(s), %d global(s)",
				file, len(wasm_funcs), len(wasm_module.imports), len(wasm_module.globals))
			for &func in wasm_module.functions {
				fmt.printfln("    $%s: %d params, %d locals, %d instructions",
					func.name, len(func.type.params), len(func.locals), len(func.body))
			}
		}

		// Emit WAT
		if format_name == "wat" || emit_all {
			wat_output := wasm.emit_wat(&wasm_module, p.arena.allocator)
			if output_dir != "" {
				stem := file_stem(file)
				out_path := fmt.tprintf("%s/%s.wat", output_dir, stem)
				write_err := os.write_entire_file(out_path, transmute([]u8)wat_output)
				if write_err != nil {
					fmt.eprintfln("mimir compile-wasm: error writing '%s': %v", out_path, write_err)
					continue
				}
				if verbose {
					fmt.printfln("  wrote %s (%d bytes)", out_path, len(wat_output))
				}
			} else {
				fmt.print(wat_output)
			}
			total_modules += 1
		}

		// Emit WASM binary
		if format_name == "wasm" || emit_all {
			wasm_bytes := wasm.emit_wasm_binary(&wasm_module, p.arena.allocator)
			if output_dir != "" {
				stem := file_stem(file)
				out_path := fmt.tprintf("%s/%s.wasm", output_dir, stem)
				write_err := os.write_entire_file(out_path, wasm_bytes)
				if write_err != nil {
					fmt.eprintfln("mimir compile-wasm: error writing '%s': %v", out_path, write_err)
					continue
				}
				if verbose {
					fmt.printfln("  wrote %s (%d bytes)", out_path, len(wasm_bytes))
				}
			} else {
				// Binary to stdout: print size info
				fmt.printfln("// WASM binary: %d bytes (magic: %02x %02x %02x %02x)",
					len(wasm_bytes),
					wasm_bytes[0] if len(wasm_bytes) > 0 else 0,
					wasm_bytes[1] if len(wasm_bytes) > 1 else 0,
					wasm_bytes[2] if len(wasm_bytes) > 2 else 0,
					wasm_bytes[3] if len(wasm_bytes) > 3 else 0)
			}
			total_modules += 1
		}

		// JS/TS bindings
		if emit_js && output_dir != "" {
			stem := file_stem(file)
			wasm_filename := fmt.tprintf("%s.wasm", stem)
			js_str := wasm.emit_js_loader(&wasm_module, wasm_filename, p.arena.allocator)
			ts_str := wasm.emit_ts_declarations(&wasm_module, p.arena.allocator)
			js_path := fmt.tprintf("%s/%s.js", output_dir, stem)
			ts_path := fmt.tprintf("%s/%s.d.ts", output_dir, stem)
			js_data := transmute([]byte)js_str
			ts_data := transmute([]byte)ts_str
			js_err := os.write_entire_file(js_path, js_data)
			ts_err := os.write_entire_file(ts_path, ts_data)
			if js_err != nil {
				fmt.eprintfln("mimir compile-wasm: error writing '%s': %v", js_path, js_err)
			}
			if ts_err != nil {
				fmt.eprintfln("mimir compile-wasm: error writing '%s': %v", ts_path, ts_err)
			}
			if verbose {
				fmt.printfln("  wrote %s, %s", js_path, ts_path)
			}
		}
	}

	if total_modules > 0 {
		fmt.printfln("mimir compile-wasm: emitted %d module(s)", total_modules)
	} else if !has_errors {
		fmt.printfln("mimir compile-wasm: no @wasm functions found in %d file(s)", len(p.files))
	}
}

// ==================== Path Helpers ====================

// Returns filename from path (e.g., "dir/foo.py" → "foo.py")
file_basename :: proc(path: string) -> string {
	last := -1
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			last = i
			break
		}
	}
	if last < 0 { return path }
	return path[last + 1:]
}

// Returns filename without extension (e.g., "dir/foo.py" → "foo")
file_stem :: proc(path: string) -> string {
	base := file_basename(path)
	for i := len(base) - 1; i >= 0; i -= 1 {
		if base[i] == '.' {
			return base[:i]
		}
	}
	return base
}

// Returns directory part with trailing slash (e.g., "dir/foo.py" → "dir/")
file_dir :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			return path[:i + 1]
		}
	}
	return ""
}
