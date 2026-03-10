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
	case "test":
		cmd_test(args[2:])
	case "remove":
		cmd_remove(args[2:])
	case "update":
		cmd_update(args[2:])
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

		// d. Collect exports
		modules.collect_exports(info, &check_result, &res_ctx)

		// e. Print summary
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

print_usage :: proc() {
	fmt.println("mimir — Python development platform")
	fmt.println()
	fmt.println("Usage: mimir <command> [options]")
	fmt.println()
	fmt.println("Commands:")
	fmt.println("  check <path>      Analyze Python source files")
	fmt.println("  test [path]       Run tests (discovers test_*.py and *_test.py files)")
	fmt.println("  run <script>      Run a Python script with automatic dependency resolution")
	fmt.println("  add <packages>    Add dependencies to mimir.toml, lock, and install")
	fmt.println("  remove <packages> Remove dependencies from mimir.toml and re-lock")
	fmt.println("  update            Re-resolve all dependencies to latest matching versions")
	fmt.println("  lock              Resolve dependencies and generate mimir.lock")
	fmt.println("  install           Install dependencies from mimir.lock")
	fmt.println("  conform [path]    Run conformance tests (default: tests/conformance/)")
	fmt.println("  version           Print version")
	fmt.println("  help              Show this message")
}
