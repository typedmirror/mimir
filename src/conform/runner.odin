package conform

import "core:mem"
import "core:os"

import "mimir:core"
import "mimir:parser"
import "mimir:binder"
import "mimir:flow"
import "mimir:checker"
import "mimir:concurrency"

Conform_File_Result :: struct {
	file:            string,
	passed:          bool,
	expected:        int,     // count of # E (required) markers
	matched:        int,     // true positives
	false_negatives: [dynamic]int,  // # E lines we missed
	false_positives: [dynamic]int,  // errors without # E
	optional_hit:    int,     // # E? lines we flagged
}

// run_conform_file runs the full pipeline on a single file and compares
// actual diagnostics against # E markers.
run_conform_file :: proc(
	bridge: ^parser.Bridge,
	file: string,
	arena: ^core.Analysis_Arena,
	allocator: mem.Allocator,
) -> Conform_File_Result {
	result: Conform_File_Result
	result.file = file
	result.false_negatives.allocator = allocator
	result.false_positives.allocator = allocator

	// Read source and parse markers
	source, read_err := os.read_entire_file(file, context.temp_allocator)
	if read_err != nil {
		// Can't read file — treat as failure with no markers
		result.passed = false
		return result
	}

	markers := parse_markers(source, allocator)

	// Build marker lookup maps
	required_lines: map[int]bool
	required_lines.allocator = context.temp_allocator
	optional_lines: map[int]bool
	optional_lines.allocator = context.temp_allocator

	for m in markers {
		switch m.kind {
		case .Required:
			required_lines[m.line] = true
			result.expected += 1
		case .Optional:
			optional_lines[m.line] = true
		}
	}

	// Reset arena and run full pipeline
	core.arena_reset(arena)

	// Collect all error lines from all pipeline stages
	error_lines: map[int]bool
	error_lines.allocator = context.temp_allocator

	module, parse_err := parser.bridge_parse(bridge, file, arena.allocator)
	if parse_err != nil {
		// Parse error — mark as line 1 error
		error_lines[1] = true
	} else {
		// Bind
		bind_result := binder.bind(module, file, arena.allocator)
		for d in bind_result.diagnostics {
			if d.severity == .Error {
				error_lines[d.location.line] = true
			}
		}

		// Flow
		flow_result := flow.analyze(module, &bind_result, file, arena.allocator)
		for d in flow_result.diagnostics {
			if d.severity == .Error {
				error_lines[d.location.line] = true
			}
		}

		// Check
		check_result := checker.check(module, &bind_result, &flow_result, file, arena.allocator)
		for d in check_result.diagnostics {
			if d.severity == .Error {
				error_lines[d.location.line] = true
			}
		}

		// Concurrency
		source_str := string(source)
		conc_diagnostics := concurrency.analyze_concurrency(module, &bind_result, source_str, file, arena.allocator)
		for d in conc_diagnostics {
			if d.severity == .Error {
				error_lines[d.location.line] = true
			}
		}
	}

	// Compare: check each required marker
	for line in required_lines {
		if line in error_lines {
			result.matched += 1
		} else {
			append(&result.false_negatives, line)
		}
	}

	// Check each actual error line
	for line in error_lines {
		if line in required_lines {
			// Already counted as matched
		} else if line in optional_lines {
			result.optional_hit += 1
		} else {
			append(&result.false_positives, line)
		}
	}

	result.passed = len(result.false_negatives) == 0 && len(result.false_positives) == 0
	return result
}
