package conform

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

import "mimir:core"
import "mimir:parser"
import "mimir:orchestrator"
import "mimir:lint"
import "mimir:security"
import "mimir:perf"
import "mimir:safety"

Conform_File_Result :: struct {
	file:            string,
	passed:          bool,
	expected:        int,     // count of # E (required) markers
	matched:        int,     // true positives
	false_negatives: [dynamic]int,  // # E lines we missed
	false_positives: [dynamic]int,  // errors without # E
	optional_hit:    int,     // # E? lines we flagged
	marker_errors:   [dynamic]string, // malformed marker messages — file fails loudly
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
	result.marker_errors.allocator = allocator

	// Read source and parse markers
	source, read_err := os.read_entire_file(file, context.temp_allocator)
	if read_err != nil {
		// Can't read file — treat as failure with no markers
		result.passed = false
		return result
	}

	markers, marker_errs := parse_markers(source, allocator)
	if len(marker_errs) > 0 {
		// Malformed markers are hard failures — never degrade to a weaker
		// assertion (a `# E[` typo silently becoming a bare `# E` would let
		// a wrong-code regression pass). Fail the file loudly, skip analysis.
		for e in marker_errs {
			append(&result.marker_errors,
				strings.clone(fmt.tprintf("L%d: malformed marker: %s", e.line, e.msg), allocator))
		}
		result.passed = false
		return result
	}

	// Build marker lookup maps
	required_lines: map[int]bool
	required_lines.allocator = context.temp_allocator
	optional_lines: map[int]bool
	optional_lines.allocator = context.temp_allocator
	marker_codes: map[int][]string // lines whose marker demands specific codes
	marker_codes.allocator = context.temp_allocator

	for m in markers {
		switch m.kind {
		case .Required:
			required_lines[m.line] = true
			result.expected += 1
		case .Optional:
			optional_lines[m.line] = true
		}
		if len(m.codes) > 0 {
			marker_codes[m.line] = m.codes
		}
	}

	// Reset arena and run full pipeline
	core.arena_reset(arena)

	// Collect all error lines from all pipeline stages.
	// error_codes additionally records which diagnostic codes fired per line
	// (composite "line:code" keys) so code-specific markers can be checked.
	error_lines: map[int]bool
	error_lines.allocator = context.temp_allocator
	error_codes: map[string]bool
	error_codes.allocator = context.temp_allocator

	module, parse_err := parser.bridge_parse(bridge, file, arena.allocator)
	if parse_err != nil {
		// Parse error — mark as line 1 error (no diagnostic code: a
		// code-specific marker on line 1 will NOT match a parse failure)
		error_lines[1] = true
	} else {
		source_str := string(source)

		// Filename-gated pass selection — the exact pre-T4 policy (R5 matrix):
		// Check+Concurrency always; Lint/Security/Perf/Safety by prefix.
		// The selection is centralized into a Pass_Set; the policy is unchanged.
		basename := file
		for i := len(file) - 1; i >= 0; i -= 1 {
			if file[i] == '/' { basename = file[i+1:]; break }
		}
		passes: orchestrator.Pass_Set = {.Check, .Concurrency}
		if strings.has_prefix(basename, "lint_") { passes += {.Lint} }
		if strings.has_prefix(basename, "sec_") || strings.has_prefix(basename, "taint_") { passes += {.Security} }
		if strings.has_prefix(basename, "perf_") { passes += {.Perf} }
		if strings.has_prefix(basename, "safety_") || strings.contains(file, "/safety/") { passes += {.Safety} }

		// Run the pipeline through the orchestrator. Virtual_Only preserves
		// conform's checker behavior exactly: private registry, virtual
		// imports only, no B003 (T4 R5 — resolution-policy harmonization is
		// explicitly out of scope).
		g := orchestrator.init(module, source_str, file, arena.allocator)
		orchestrator.run(&g, orchestrator.Run_Config{
			passes          = passes,
			resolution      = .Virtual_Only,
			lint_config     = lint.default_config(),
			security_config = security.default_config(),
			perf_config     = perf.default_config(),
			safety_config   = safety.default_config(),
		})

		// Collect from the PER-PASS lists with the pre-T4 severity semantics,
		// byte-for-byte: bind/flow/check count Errors only; concurrency and
		// the filename-gated passes count all severities (CONC004/006 are
		// Warning). Flow is read after run() — F002 suppression has applied.
		// Ungated pass lists are nil ⇒ zero iterations.
		for d in g.bind_result.diagnostics {
			if d.severity == .Error {
				_record_error(&error_lines, &error_codes, d.location.line, d.code)
			}
		}
		for d in g.flow_result.diagnostics {
			if d.severity == .Error {
				_record_error(&error_lines, &error_codes, d.location.line, d.code)
			}
		}
		for d in g.check_result.diagnostics {
			if d.severity == .Error {
				_record_error(&error_lines, &error_codes, d.location.line, d.code)
			}
		}
		for d in g.conc_diags {
			_record_error(&error_lines, &error_codes, d.location.line, d.code)
		}
		for d in g.lint_diags {
			_record_error(&error_lines, &error_codes, d.location.line, d.code)
		}
		for d in g.sec_diags {
			_record_error(&error_lines, &error_codes, d.location.line, d.code)
		}
		for d in g.perf_diags {
			_record_error(&error_lines, &error_codes, d.location.line, d.code)
		}
		for d in g.safety_diags {
			_record_error(&error_lines, &error_codes, d.location.line, d.code)
		}
	}

	// Compare: check each required marker.
	// Bare `# E` markers match any error on the line (legacy semantics,
	// byte-for-byte unchanged). Code markers `# E[CODE]` additionally
	// require that one of the listed codes actually fired on that line —
	// a line-level error with the wrong code is a false negative.
	for line in required_lines {
		hit := line in error_lines
		if hit {
			if codes, has_codes := marker_codes[line]; has_codes {
				hit = false
				for c in codes {
					if fmt.tprintf("%d:%s", line, c) in error_codes {
						hit = true
						break
					}
				}
			}
		}
		if hit {
			result.matched += 1
		} else {
			append(&result.false_negatives, line)
		}
	}

	// Check each actual error line.
	// NOTE (T3a parity, lead-approved): a code-marked line absorbs ANY
	// additional unexpected codes on the same line exactly like a legacy
	// line-level marker — only line membership is checked here. T3b may
	// tighten this to per-code false-positive accounting.
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

// _record_error records an error line and, when the diagnostic carries a
// code, a composite "line:code" key for code-specific marker matching.
@(private = "file")
_record_error :: proc(error_lines: ^map[int]bool, error_codes: ^map[string]bool, line: int, code: string) {
	error_lines[line] = true
	if len(code) > 0 {
		error_codes[fmt.tprintf("%d:%s", line, code)] = true
	}
}
