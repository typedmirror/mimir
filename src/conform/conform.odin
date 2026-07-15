package conform

import "core:fmt"
import "core:os"
import "core:slice"

import "mimir:core"
import "mimir:parser"

Conform_Summary :: struct {
	total_files:   int,
	passed:        int,
	failed:        int,
	total_expected: int,
	total_matched: int,
	total_fn:      int,
	total_fp:      int,
}

// cmd_conform is the entry point for `mimir conform [path]`.
cmd_conform :: proc(args: []string) {
	// Parse flags
	summary_only := false
	verbose := false
	target := "tests/conformance"

	for arg in args {
		switch arg {
		case "--summary":
			summary_only = true
		case "--verbose":
			verbose = true
		case:
			target = arg
		}
	}

	// Find test files
	files, find_err := core.find_python_files(target)
	if find_err != nil {
		fmt.eprintfln("mimir conform: error reading '%s': %v", target, find_err)
		os.exit(1)
	}
	if len(files) == 0 {
		fmt.eprintfln("mimir conform: no Python files found in '%s'", target)
		return
	}

	// Sort files for deterministic output
	slice.sort(files)

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

	// Run each file
	summary: Conform_Summary
	summary.total_files = len(files)

	for file in files {
		result := run_conform_file(&bridge, file, &arena, context.allocator)

		summary.total_expected += result.expected
		summary.total_matched += result.matched
		summary.total_fn += len(result.false_negatives)
		summary.total_fp += len(result.false_positives)

		if result.passed {
			summary.passed += 1
			if verbose {
				fmt.printfln("  PASS  %s (%d/%d markers)", file, result.matched, result.expected)
			}
		} else {
			summary.failed += 1
			if !summary_only {
				fmt.printfln("  FAIL  %s", file)
				for e in result.marker_errors {
					fmt.printfln("    %s", e)
				}
				if len(result.false_negatives) > 0 {
					slice.sort(result.false_negatives[:])
					fmt.printf("    missed errors (FN):")
					for line in result.false_negatives {
						fmt.printf(" L%d", line)
					}
					fmt.println()
				}
				if len(result.false_positives) > 0 {
					slice.sort(result.false_positives[:])
					fmt.printf("    unexpected errors (FP):")
					for line in result.false_positives {
						fmt.printf(" L%d", line)
					}
					fmt.println()
				}
			}
		}
	}

	// Print summary
	fmt.println()
	if summary.failed == 0 {
		fmt.printfln("mimir conform: %d/%d passed, %d/%d markers matched",
			summary.passed, summary.total_files,
			summary.total_matched, summary.total_expected)
	} else {
		fmt.printfln("mimir conform: %d/%d passed (%d failed), %d/%d markers matched, %d FN, %d FP",
			summary.passed, summary.total_files, summary.failed,
			summary.total_matched, summary.total_expected,
			summary.total_fn, summary.total_fp)
		os.exit(1)
	}
}
