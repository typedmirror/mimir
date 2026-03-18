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

// Every diagnostic answers: what, why, how to fix.
Diagnostic :: struct {
	severity: Severity,
	location: Location,
	what:     string,
	why:      string,
	fix:      string,
	code:     string, // e.g. "E001", "W042", "S003"
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
