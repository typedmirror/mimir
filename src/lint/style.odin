package lint

import "core:strings"
import "core:unicode/utf8"
import core "mimir:core"

// S001 — Line too long
check_line_too_long :: proc(ctx: ^Lint_Context) {
	max_len := ctx.config.line_length
	if max_len <= 0 { max_len = 88 }

	for line, idx in ctx.lines {
		if utf8.rune_count_in_string(line) <= max_len { continue }

		// Exception: lines that are just a URL (possibly with comment prefix)
		trimmed := strings.trim_space(line)
		content := trimmed
		// Strip leading comment markers
		if strings.has_prefix(content, "#") {
			content = strings.trim_left(content[1:], " ")
		}
		if strings.has_prefix(content, "http://") || strings.has_prefix(content, "https://") {
			// Check no other content after the URL (no spaces in the URL-only part)
			if !strings.contains(content, " ") {
				continue
			}
		}

		append(&ctx.diagnostics, core.Diagnostic{
			severity = .Suggestion,
			location = core.Location{
				file   = ctx.file_path,
				line   = idx + 1,
				column = max_len + 1,
			},
			what = "line too long",
			why  = "long lines reduce readability; PEP 8 recommends a maximum line length",
			fix  = "break the line or reduce expression complexity",
			code = "S001",
		})
	}
}
