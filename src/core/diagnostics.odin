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
