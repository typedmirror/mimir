package security

import "core:fmt"
import "core:strings"
import parser "mimir:parser"
import core "mimir:core"

// SEC009 — Typosquat suspect (edit distance 1 from popular package)
check_typosquat :: proc(ctx: ^Security_Context) {
	// Check each import for proximity to popular packages
	for stmt in ctx.module.body {
		check_imports_typosquat(ctx, stmt)
	}
}

check_imports_typosquat :: proc(ctx: ^Security_Context, stmt: parser.Stmt) {
	#partial switch s in stmt {
	case ^parser.Import_Stmt:
		for alias in s.names {
			name := alias.name
			// For dotted imports, check first component
			for i := 0; i < len(name); i += 1 {
				if name[i] == '.' {
					name = name[:i]
					break
				}
			}
			check_typosquat_name(ctx, name, s.loc)
		}
	case ^parser.Import_From:
		if s.level > 0 { return } // skip relative imports
		if s.module != "" {
			name := s.module
			for i := 0; i < len(name); i += 1 {
				if name[i] == '.' {
					name = name[:i]
					break
				}
			}
			check_typosquat_name(ctx, name, s.loc)
		}
	case ^parser.Func_Def:
		for st in s.body { check_imports_typosquat(ctx, st) }
	case ^parser.Async_Func_Def:
		for st in s.body { check_imports_typosquat(ctx, st) }
	case ^parser.Class_Def:
		for st in s.body { check_imports_typosquat(ctx, st) }
	case ^parser.If_Stmt:
		for st in s.body { check_imports_typosquat(ctx, st) }
		for st in s.orelse { check_imports_typosquat(ctx, st) }
	}
}

check_typosquat_name :: proc(ctx: ^Security_Context, name: string, loc: parser.Src_Loc) {
	for pkg in POPULAR_PACKAGES {
		if name == pkg { return } // exact match — not a typo
	}

	for pkg in POPULAR_PACKAGES {
		dist := levenshtein(name, pkg)
		if dist == 1 {
			append(&ctx.diagnostics, core.Diagnostic{
				severity = .Security,
				location = core.Location{
					file   = ctx.file_path,
					line   = int(loc.line),
					column = int(loc.col),
				},
				what = fmt.tprintf("import '%s' is similar to popular package '%s' — possible typosquatting", name, pkg),
				why  = "typosquatting packages mimic popular packages to deliver malware",
				fix  = "verify the package name is correct",
				code = "SEC009",
			})
			return // report first match only
		}
	}
}

// Levenshtein distance between two strings
levenshtein :: proc(a, b: string) -> int {
	la := len(a)
	lb := len(b)

	if la == 0 { return lb }
	if lb == 0 { return la }

	// Use two rows instead of full matrix
	prev := make([]int, lb + 1, context.temp_allocator)
	curr := make([]int, lb + 1, context.temp_allocator)

	for j := 0; j <= lb; j += 1 {
		prev[j] = j
	}

	for i := 1; i <= la; i += 1 {
		curr[0] = i
		for j := 1; j <= lb; j += 1 {
			cost := 0 if a[i - 1] == b[j - 1] else 1
			del := prev[j] + 1
			ins := curr[j - 1] + 1
			sub := prev[j - 1] + cost
			curr[j] = min(del, ins, sub)
		}
		// Swap rows
		prev, curr = curr, prev
	}

	return prev[lb]
}

POPULAR_PACKAGES := [?]string{
	"requests", "flask", "django", "numpy", "pandas",
	"scipy", "sklearn", "tensorflow", "pytorch", "torch",
	"boto3", "sqlalchemy", "celery", "redis", "psycopg2",
	"pymongo", "httpx", "fastapi", "pydantic", "cryptography",
	"paramiko", "pillow", "beautifulsoup4", "selenium", "scrapy",
	"matplotlib", "seaborn", "plotly", "pytest", "setuptools",
	"pip", "wheel", "black", "ruff", "mypy",
	"pylint", "isort", "coverage", "tox", "sphinx",
	"jinja2", "markupsafe", "werkzeug", "click", "rich",
	"typer", "aiohttp", "uvicorn", "gunicorn", "docker",
	"kubernetes",
}
