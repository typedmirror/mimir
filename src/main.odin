package mimir

import "core:fmt"
import "core:os"
import "core:strings"

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

main :: proc() {
	args := os.args
	if len(args) < 2 {
		print_usage()
		os.exit(1)
	}

	command := args[1]

	switch command {
	case "check":
		cmd_check(args[2:])
	case "conform":
		conform.cmd_conform(args[2:])
	case "run":
		cmd_run(args[2:])
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
	case "python":
		cmd_python(args[2:])
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

cmd_version :: proc() {
	fmt.println("mimir 0.0.1-dev")
}

cmd_check :: proc(args: []string) {
	if len(args) == 0 {
		fmt.eprintln("mimir check: no input path specified")
		fmt.eprintln("Usage: mimir check <path>")
		os.exit(1)
	}

	target := args[0]

	// Find Python files
	files, find_err := core.find_python_files(target)
	if find_err != nil {
		fmt.eprintfln("mimir: error reading '%s': %v", target, find_err)
		os.exit(1)
	}
	if len(files) == 0 {
		fmt.eprintfln("mimir: no Python files found in '%s'", target)
		return
	}

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

	// Initialize analysis arena
	arena: core.Analysis_Arena
	arena_err := core.arena_init(&arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize analysis arena")
		os.exit(1)
	}
	defer core.arena_destroy(&arena)

	// Single file: fast path (existing behavior)
	if len(files) == 1 {
		cmd_check_single(files[0], &bridge, &arena)
	} else {
		// Multi-module: shared registry + module graph
		cmd_check_multi(target, files, &bridge, &arena)
	}
}

// Single-file check — original behavior, unchanged
cmd_check_single :: proc(
	file: string,
	bridge: ^parser.Bridge,
	arena: ^core.Analysis_Arena,
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

	bind_result := binder.bind(module, file, arena.allocator)
	for d in bind_result.diagnostics {
		core.diagnostic_print(d)
		if d.severity == .Error { error_count += 1 }
	}

	flow_result := flow.analyze(module, &bind_result, file, arena.allocator)
	for d in flow_result.diagnostics {
		core.diagnostic_print(d)
		if d.severity == .Error { error_count += 1 }
	}

	check_result := checker.check(module, &bind_result, &flow_result, file, arena.allocator)
	for d in check_result.diagnostics {
		core.diagnostic_print(d)
		if d.severity == .Error { error_count += 1 }
	}

	// Concurrency analysis
	source_data, src_err := os.read_entire_file(file, arena.allocator)
	source_str := string(source_data) if src_err == nil else ""
	conc_diagnostics := concurrency.analyze_concurrency(module, &bind_result, source_str, file, arena.allocator)
	for d in conc_diagnostics {
		core.diagnostic_print(d)
		if d.severity == .Error { error_count += 1 }
	}

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

	return error_count
}

// Multi-module check — shared registry, import resolution
cmd_check_multi :: proc(
	root_path: string,
	files: []string,
	bridge: ^parser.Bridge,
	arena: ^core.Analysis_Arena,
) {
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

	// 6. Init resolution context
	res_ctx := modules.init_resolution_context(&registry, arena.allocator)

	// 7. For each module in topo order: resolve → flow → check → export
	error_count := parse_errors
	for name in graph.topo_order {
		info, ok := graph.modules[name]
		if !ok || info.parse_result == nil { continue }

		// Report binder diagnostics
		for d in info.bind_result.diagnostics {
			core.diagnostic_print(d)
			if d.severity == .Error { error_count += 1 }
		}

		// a. Resolve imports
		import_types := modules.resolve_imports(info, &res_ctx)

		// b. Flow analysis
		flow_result := flow.analyze(info.parse_result, &info.bind_result, info.file_path, arena.allocator)
		for d in flow_result.diagnostics {
			core.diagnostic_print(d)
			if d.severity == .Error { error_count += 1 }
		}

		// c. Type check with imports
		check_result := checker.check_with_imports(
			info.parse_result, &info.bind_result, &flow_result,
			info.file_path, &registry, &builtins, import_types, arena.allocator)
		for d in check_result.diagnostics {
			core.diagnostic_print(d)
			if d.severity == .Error { error_count += 1 }
		}

		// d. Concurrency analysis
		conc_source_data, conc_src_err := os.read_entire_file(info.file_path, arena.allocator)
		conc_source := string(conc_source_data) if conc_src_err == nil else ""
		conc_diagnostics := concurrency.analyze_concurrency(
			info.parse_result, &info.bind_result, conc_source, info.file_path, arena.allocator)
		for d in conc_diagnostics {
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
	locked, resolve_err := platform.resolve(python, config.dependencies[:], allocator)
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
	locked, resolve_err := platform.resolve(python, config.dependencies[:], allocator)
	if resolve_err != nil {
		fmt.eprintfln("mimir lock: %s", platform.error_msg(resolve_err))
		os.exit(1)
	}

	lf := platform.Lockfile{
		packages = make([dynamic]platform.Locked_Package, len(locked), allocator),
	}
	copy(lf.packages[:], locked)

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

	install_err := platform.install_from_lockfile(python, &lf, &cache, allocator)
	if install_err != nil {
		fmt.eprintfln("mimir install: %s", platform.error_msg(install_err))
		os.exit(1)
	}
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
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintfln("mimir test: unknown flag '%s'", arg)
			fmt.eprintln("Usage: mimir test [-k <pattern>] [--check] [-v] [path]")
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

	// Find Python files
	files, find_err := core.find_python_files(target)
	if find_err != nil {
		fmt.eprintfln("mimir lint: error reading '%s': %v", target, find_err)
		os.exit(1)
	}
	if len(files) == 0 {
		fmt.eprintfln("mimir lint: no Python files found in '%s'", target)
		return
	}

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

	// Arena
	arena: core.Analysis_Arena
	arena_err := core.arena_init(&arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize analysis arena")
		os.exit(1)
	}
	defer core.arena_destroy(&arena)

	total_warnings := 0
	files_with_warnings := 0

	for file in files {
		// Read source
		source_data, read_err := os.read_entire_file(file, arena.allocator)
		if read_err != nil {
			fmt.eprintfln("mimir lint: cannot read '%s': %v", file, read_err)
			continue
		}
		source := string(source_data)

		// Parse
		module, parse_err := parser.bridge_parse(&bridge, file, arena.allocator)
		if parse_err != nil {
			switch e in parse_err {
			case parser.Syntax_Error:
				fmt.eprintfln("%s:%d:%d: error: %s", e.file, e.line, e.col, e.msg)
			case parser.Bridge_Error:
				fmt.eprintfln("mimir lint: %s: %s", file, e.msg)
			}
			continue
		}

		// Bind
		bind_result := binder.bind(module, file, arena.allocator)

		// Lint
		diagnostics := lint.lint_file(module, &bind_result, source, file, &config, arena.allocator)

		if len(diagnostics) > 0 {
			files_with_warnings += 1
			total_warnings += len(diagnostics)
			for d in diagnostics {
				core.diagnostic_print(d)
			}
		}
	}

	if total_warnings > 0 {
		fmt.printfln("mimir lint: %d warning(s) in %d file(s)", total_warnings, files_with_warnings)
		os.exit(1)
	} else {
		fmt.printfln("mimir lint: %d file(s) clean", len(files))
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

	// Find Python files
	files, find_err := core.find_python_files(target)
	if find_err != nil {
		fmt.eprintfln("mimir perf: error reading '%s': %v", target, find_err)
		os.exit(1)
	}
	if len(files) == 0 {
		fmt.eprintfln("mimir perf: no Python files found in '%s'", target)
		return
	}

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

	// Arena
	arena: core.Analysis_Arena
	arena_err := core.arena_init(&arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize analysis arena")
		os.exit(1)
	}
	defer core.arena_destroy(&arena)

	total_issues := 0
	files_with_issues := 0

	for file in files {
		// Read source
		source_data, read_err := os.read_entire_file(file, arena.allocator)
		if read_err != nil {
			fmt.eprintfln("mimir perf: cannot read '%s': %v", file, read_err)
			continue
		}
		source := string(source_data)

		// Parse
		module, parse_err := parser.bridge_parse(&bridge, file, arena.allocator)
		if parse_err != nil {
			switch e in parse_err {
			case parser.Syntax_Error:
				fmt.eprintfln("%s:%d:%d: error: %s", e.file, e.line, e.col, e.msg)
			case parser.Bridge_Error:
				fmt.eprintfln("mimir perf: %s: %s", file, e.msg)
			}
			continue
		}

		// Bind
		bind_result := binder.bind(module, file, arena.allocator)

		// Performance analysis
		diagnostics := perf.analyze_performance(module, &bind_result, source, file, &config, arena.allocator)

		if len(diagnostics) > 0 {
			files_with_issues += 1
			total_issues += len(diagnostics)
			for d in diagnostics {
				core.diagnostic_print(d)
			}
		}
	}

	if total_issues > 0 {
		fmt.printfln("mimir perf: %d performance issue(s) in %d file(s)", total_issues, files_with_issues)
		os.exit(1)
	} else {
		fmt.printfln("mimir perf: %d file(s) clean", len(files))
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

	// Find Python files
	files, find_err := core.find_python_files(target)
	if find_err != nil {
		fmt.eprintfln("mimir audit: error reading '%s': %v", target, find_err)
		os.exit(1)
	}
	if len(files) == 0 {
		fmt.eprintfln("mimir audit: no Python files found in '%s'", target)
		return
	}

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

	// Arena
	arena: core.Analysis_Arena
	arena_err := core.arena_init(&arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize analysis arena")
		os.exit(1)
	}
	defer core.arena_destroy(&arena)

	total_issues := 0
	files_with_issues := 0

	for file in files {
		if verbose {
			fmt.printfln("  scanning %s", file)
		}

		// Read source
		source_data, read_err := os.read_entire_file(file, arena.allocator)
		if read_err != nil {
			fmt.eprintfln("mimir audit: cannot read '%s': %v", file, read_err)
			continue
		}
		source := string(source_data)

		// Parse
		module, parse_err := parser.bridge_parse(&bridge, file, arena.allocator)
		if parse_err != nil {
			switch e in parse_err {
			case parser.Syntax_Error:
				fmt.eprintfln("%s:%d:%d: error: %s", e.file, e.line, e.col, e.msg)
			case parser.Bridge_Error:
				fmt.eprintfln("mimir audit: %s: %s", file, e.msg)
			}
			continue
		}

		// Bind (needed for import resolution)
		bind_result := binder.bind(module, file, arena.allocator)

		// Flow analysis (needed for taint tracking)
		flow_result := flow.analyze(module, &bind_result, file, arena.allocator)

		// Security scan (with taint analysis via flow_result)
		diagnostics := security.scan_file(module, &bind_result, source, file, &config, arena.allocator, &flow_result)

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
		fmt.printfln("mimir audit: %d file(s) clean", len(files))
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
	locked, resolve_err := platform.resolve(python, config.dependencies[:], allocator)
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
	locked, resolve_err := platform.resolve(python, config.dependencies[:], allocator)
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

	files, find_err := core.find_python_files(target)
	if find_err != nil {
		fmt.eprintfln("mimir safety: error reading '%s': %v", target, find_err)
		os.exit(1)
	}
	if len(files) == 0 {
		fmt.eprintfln("mimir safety: no Python files found in '%s'", target)
		return
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
	defer parser.bridge_stop(&bridge)

	arena: core.Analysis_Arena
	arena_err := core.arena_init(&arena)
	if arena_err != nil {
		fmt.eprintln("mimir: failed to initialize analysis arena")
		os.exit(1)
	}
	defer core.arena_destroy(&arena)

	total_issues := 0
	files_with_issues := 0

	for file in files {
		module, parse_err := parser.bridge_parse(&bridge, file, arena.allocator)
		if parse_err != nil {
			switch e in parse_err {
			case parser.Syntax_Error:
				fmt.eprintfln("%s:%d:%d: error: %s", e.file, e.line, e.col, e.msg)
			case parser.Bridge_Error:
				fmt.eprintfln("mimir safety: %s: %s", file, e.msg)
			}
			continue
		}

		bind_result := binder.bind(module, file, arena.allocator)

		diagnostics := safety.analyze_safety(module, &bind_result, file, &config, arena.allocator)

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
		fmt.printfln("mimir safety: %d file(s) clean", len(files))
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
	fmt.println("  audit [path]      Scan Python files for security vulnerabilities (default: \".\")")
	fmt.println("  lint [path]       Lint Python files for common issues (default: \".\")")
	fmt.println("  safety [path]     Detect Python safety issues (default: \".\")")
	fmt.println("  perf [path]       Detect Python performance anti-patterns (default: \".\")")
	fmt.println("  test [path]       Run tests (discovers test_*.py and *_test.py files)")
	fmt.println("  repl              Start type-aware interactive Python REPL")
	fmt.println("  lsp               Start LSP server for editor integration")
	fmt.println("  run <script>      Run a Python script with automatic dependency resolution")
	fmt.println("  build [path]      Build wheel + sdist package (output to dist/)")
	fmt.println("  publish [path]    Publish package to PyPI (builds if needed)")
	fmt.println("  python <cmd>      Manage Python versions (install, list, remove)")
	fmt.println("  add <packages>    Add dependencies to mimir.toml, lock, and install")
	fmt.println("  remove <packages> Remove dependencies from mimir.toml and re-lock")
	fmt.println("  update            Re-resolve all dependencies to latest matching versions")
	fmt.println("  lock              Resolve dependencies and generate mimir.lock")
	fmt.println("  install           Install dependencies from mimir.lock")
	fmt.println("  conform [path]    Run conformance tests (default: tests/conformance/)")
	fmt.println("  version           Print version")
	fmt.println("  help              Show this message")
}
