package orchestrator

// Output-shaping level helpers — moved from main.odin (T4, R2): the
// orchestrator owns diagnostic emission via print_diagnostics, so the
// level/suppression filters it applies live in the same package.

import "core:strings"

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
// Supports: # mimir: ignore, # type: ignore (suppress all)
// and # mimir: ignore[T001] or # mimir: ignore[T001, T002]
is_line_suppressed :: proc(code: string, line_num: int, source_lines: []string) -> bool {
	idx := line_num - 1
	if idx < 0 || idx >= len(source_lines) { return false }
	line := source_lines[idx]

	// Check for # type: ignore (mypy-compatible blanket suppression)
	if strings.index(line, "# type: ignore") >= 0 { return true }

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
