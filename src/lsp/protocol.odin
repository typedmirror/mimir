package lsp

// LSP 3.17 protocol types — minimal subset for MVP.
// Only the types we actually use for initialize, diagnostics, hover, definition, references.

// ==================== Basic Types ====================

Position :: struct {
	line:      int, // 0-indexed
	character: int, // 0-indexed
}

Range :: struct {
	start: Position,
	end:   Position,
}

Location :: struct {
	uri:   string,
	range: Range,
}

// ==================== Text Document ====================

Text_Document_Identifier :: struct {
	uri: string,
}

Text_Document_Item :: struct {
	uri:         string,
	language_id: string,
	version:     int,
	text:        string,
}

// ==================== Diagnostics ====================

Diagnostic_Severity :: enum {
	Error       = 1,
	Warning     = 2,
	Information = 3,
	Hint        = 4,
}

LSP_Diagnostic :: struct {
	range:    Range,
	severity: int,
	code:     string,
	source:   string,
	message:  string,
}

// ==================== Hover ====================

Markup_Content :: struct {
	kind:  string, // "markdown" or "plaintext"
	value: string,
}

Hover :: struct {
	contents: Markup_Content,
	range:    Range,
}

// ==================== Capabilities ====================

Text_Document_Sync_Kind :: enum {
	None        = 0,
	Full        = 1,
	Incremental = 2,
}
