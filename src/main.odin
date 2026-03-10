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
) {
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
		return
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
	exit_code := platform.run(config, arena.allocator)
	core.arena_destroy(&arena)
	os.exit(exit_code)
}

print_usage :: proc() {
	fmt.println("mimir — Python development platform")
	fmt.println()
	fmt.println("Usage: mimir <command> [options]")
	fmt.println()
	fmt.println("Commands:")
	fmt.println("  check <path>    Analyze Python source files")
	fmt.println("  run <script>    Run a Python script with automatic dependency resolution")
	fmt.println("  conform [path]  Run conformance tests (default: tests/conformance/)")
	fmt.println("  version         Print version")
	fmt.println("  help            Show this message")
}
