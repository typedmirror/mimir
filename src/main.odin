package mimir

import "core:fmt"
import "core:os"

import "core"
import "parser"
import "binder"

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

	// Parse each file
	error_count := 0
	for file in files {
		module, parse_err := parser.bridge_parse(&bridge, file, arena.allocator)
		if parse_err != nil {
			error_count += 1
			switch e in parse_err {
			case parser.Syntax_Error:
				fmt.eprintfln("%s:%d:%d: error: %s", e.file, e.line, e.col, e.msg)
			case parser.Bridge_Error:
				fmt.eprintfln("mimir: %s: %s", file, e.msg)
			}
			continue
		}
		// Bind the module
		bind_result := binder.bind(module, file, arena.allocator)

		// Report binder diagnostics
		for d in bind_result.diagnostics {
			core.diagnostic_print(d)
			if d.severity == .Error {
				error_count += 1
			}
		}

		fmt.printfln("  parsed %s (%d stmts, %d symbols, %d scopes)",
			file, len(module.body),
			len(bind_result.symbols), len(bind_result.scopes))
	}

	if error_count > 0 {
		fmt.eprintfln("mimir: %d file(s) had errors", error_count)
	} else {
		fmt.printfln("mimir: successfully checked %d file(s)", len(files))
	}
}

print_usage :: proc() {
	fmt.println("mimir — Python development platform")
	fmt.println()
	fmt.println("Usage: mimir <command> [options]")
	fmt.println()
	fmt.println("Commands:")
	fmt.println("  check <path>    Analyze Python source files")
	fmt.println("  version         Print version")
	fmt.println("  help            Show this message")
}
