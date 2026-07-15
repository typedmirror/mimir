package core

import "core:fmt"

Severity :: enum {
	Error,
	Warning,
	Security,
	Performance,
	Suggestion,
	Info,
}

// Source location within a Python file.
Location :: struct {
	file:   string,
	line:   int,
	column: int,
}

// Confidence in the diagnostic's correctness.
// Determined by the reasoning engine that produced it.
Confidence :: enum u8 {
	Unknown,    // Not yet classified (zero value — backwards compatible)
	Proven,     // Type system proof: definitely wrong (T001, T003, T005, B001)
	High,       // Strong analysis: very likely correct (F002, D001, T007)
	Medium,     // Pattern matching: may have edge cases (SEC*, CONC*, SAF*)
	Advisory,   // Style/convention/performance: subjective (L*, PERF*, C*)
}

// Every diagnostic answers: what, why, how to fix.
Diagnostic :: struct {
	severity:   Severity,
	location:   Location,
	what:       string,
	why:        string,
	fix:        string,
	code:       string,     // e.g. "E001", "W042", "S003"
	confidence: Confidence, // zero-initialized to .Unknown — resolved by code prefix
}

// Emit a SARIF JSON document from a list of diagnostics.
diagnostics_to_sarif :: proc(diagnostics: []Diagnostic, version: string) -> string {
	b := fmt.tprintf(`{{"$schema":"https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json","version":"2.1.0","runs":[{{"tool":{{"driver":{{"name":"mimir","version":"%s"}}}},"results":[`, version)
	result: [dynamic]string
	append(&result, b)
	for d, i in diagnostics {
		if i > 0 { append(&result, ",") }
		level := "error"
		switch d.severity {
		case .Error:       level = "error"
		case .Warning:     level = "warning"
		case .Security:    level = "error"
		case .Performance: level = "note"
		case .Suggestion:  level = "note"
		case .Info:        level = "note"
		}
		append(&result, fmt.tprintf(
			`{{"ruleId":"%s","level":"%s","message":{{"text":"%s"}},"locations":[{{"physicalLocation":{{"artifactLocation":{{"uri":"%s"}},"region":{{"startLine":%d,"startColumn":%d}}}}}}]}}`,
			d.code, level,
			_sarif_escape(d.what),
			_sarif_escape(d.location.file),
			d.location.line, max(d.location.column, 1),
		))
	}
	append(&result, "]}]}")
	// Join
	total := 0
	for s in result { total += len(s) }
	buf := make([]u8, total)
	offset := 0
	for s in result {
		copy(buf[offset:], transmute([]u8)s)
		offset += len(s)
	}
	return string(buf)
}

_sarif_escape :: proc(s: string) -> string {
	// Escape quotes and backslashes for JSON string
	needs_escape := false
	for i := 0; i < len(s); i += 1 {
		if s[i] == '"' || s[i] == '\\' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t' {
			needs_escape = true
			break
		}
	}
	if !needs_escape { return s }
	buf := make([dynamic]u8, 0, len(s) + 16)
	for i := 0; i < len(s); i += 1 {
		switch s[i] {
		case '"':  append(&buf, '\\'); append(&buf, '"')
		case '\\': append(&buf, '\\'); append(&buf, '\\')
		case '\n': append(&buf, '\\'); append(&buf, 'n')
		case '\r': append(&buf, '\\'); append(&buf, 'r')
		case '\t': append(&buf, '\\'); append(&buf, 't')
		case:      append(&buf, s[i])
		}
	}
	return string(buf[:])
}

// Resolve confidence from diagnostic code prefix when not explicitly set.
resolve_confidence :: proc(code: string) -> Confidence {
	if len(code) == 0 { return .Unknown }

	// Type system proofs — definitely wrong
	switch code {
	case "T001", "T002", "T003", "T004", "T005", "T006", "T008", "T009", "T011", "T012":
		return .Proven
	case "B001", "B002", "B004", "B005":
		return .Proven
	case "F001":  // unreachable code — proven by CFG
		return .Proven
	case "P001":  // parser recovery — the drop definitely happened
		return .Proven
	}

	// Strong analysis — very likely correct
	switch code {
	case "T007", "T010":
		return .High
	case "F002", "D001":
		return .High
	case "B003":  // unresolved import — resolution failure is fact; impact is environment-dependent
		return .High
	case "MATCH001", "MATCH002":
		return .High
	}

	// Pattern-based — check prefix
	prefix := code[:1] if len(code) >= 1 else ""
	// Two+ char prefixes
	if len(code) >= 3 {
		if code[:3] == "SEC" || code[:3] == "SAF" { return .Medium }
	}
	if len(code) >= 4 {
		if code[:4] == "CONC" || code[:4] == "PROC" || code[:4] == "DATA" { return .Medium }
		if code[:4] == "PERF" { return .Advisory }
		if code[:4] == "COMP" { return .Medium }  // compat
	}
	if len(code) >= 2 {
		if code[:2] == "RT" || code[:2] == "DB" { return .Medium }
		if code[:2] == "MIG" { return .Advisory }
		if code[:2] == "GPU" { return .Medium }
	}

	switch prefix {
	case "L", "C": return .Advisory   // lint, convention
	case "S":      return .Medium     // security (S001 etc.)
	}

	return .Unknown
}

diagnostic_print :: proc(d: Diagnostic) {
	severity_str: string
	switch d.severity {
	case .Error:
		severity_str = "error"
	case .Warning:
		severity_str = "warning"
	case .Security:
		severity_str = "security"
	case .Performance:
		severity_str = "performance"
	case .Suggestion:
		severity_str = "suggestion"
	case .Info:
		severity_str = "info"
	}

	fmt.printfln(
		"%s:%d:%d: %s[%s]: %s",
		d.location.file,
		d.location.line,
		d.location.column,
		severity_str,
		d.code,
		d.what,
	)

	if len(d.why) > 0 {
		fmt.printfln("  why: %s", d.why)
	}
	if len(d.fix) > 0 {
		fmt.printfln("  fix: %s", d.fix)
	}
}

// Print with confidence annotation (for --verbose or --confidence modes)
diagnostic_print_with_confidence :: proc(d: Diagnostic) {
	conf := d.confidence
	if conf == .Unknown { conf = resolve_confidence(d.code) }

	severity_str: string
	switch d.severity {
	case .Error:       severity_str = "error"
	case .Warning:     severity_str = "warning"
	case .Security:    severity_str = "security"
	case .Performance: severity_str = "performance"
	case .Suggestion:  severity_str = "suggestion"
	case .Info:        severity_str = "info"
	}

	conf_str: string
	switch conf {
	case .Proven:  conf_str = "proven"
	case .High:    conf_str = "high"
	case .Medium:  conf_str = "medium"
	case .Advisory: conf_str = "advisory"
	case .Unknown: conf_str = "unknown"
	}

	fmt.printfln(
		"%s:%d:%d: %s[%s|%s]: %s",
		d.location.file,
		d.location.line,
		d.location.column,
		severity_str,
		d.code,
		conf_str,
		d.what,
	)

	if len(d.why) > 0 {
		fmt.printfln("  why: %s", d.why)
	}
	if len(d.fix) > 0 {
		fmt.printfln("  fix: %s", d.fix)
	}
}
