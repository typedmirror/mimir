package checker

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:strconv"

import parser "mimir:parser"
import binder "mimir:binder"
import core   "mimir:core"

// ==================== Dependency & Environment Analysis ====================
//
// §19.2: Python version compatibility — syntax features vs declared minimum.
// §19.3: Unused/missing dependencies — imports vs mimir.toml [dependencies].
//
// Diagnostics:
//   COMPAT001 — Python version incompatibility (syntax requires newer Python)
//   COMPAT002 — Deprecated library API usage (§19.1)
//   DEP001    — Unused dependency (declared but never imported)
//   DEP002    — Missing dependency (imported but not declared, not stdlib)

Py_Version :: struct {
	major: int,
	minor: int,
}

Compat_Context :: struct {
	file_path:   string,
	diagnostics: ^[dynamic]core.Diagnostic,
	min_version: Py_Version,
	allocator:   mem.Allocator,
}

// Entry point — called from checker.odin after type checking.
analyze_compat :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	// Find mimir.toml
	dir := file_path
	for i := len(dir) - 1; i >= 0; i -= 1 {
		if dir[i] == '/' {
			dir = dir[:i]
			break
		}
	}

	// §19.1: Deprecated library API usage (runs regardless of mimir.toml)
	check_deprecated_apis(module, bind_result, file_path, diagnostics, allocator)

	config_path, min_version, deps := read_compat_config(dir, allocator)
	if len(config_path) == 0 { return }

	// §19.2: Python version compatibility
	if min_version.major > 0 {
		ctx := Compat_Context{
			file_path   = file_path,
			diagnostics = diagnostics,
			min_version = min_version,
			allocator   = allocator,
		}

		visitor := core.AST_Visitor{
			visit_stmt = proc(stmt: parser.Stmt, raw_ctx: rawptr) {
				ctx := cast(^Compat_Context)raw_ctx
				check_stmt_compat(ctx, stmt)
			},
			visit_expr = proc(expr: parser.Expr, raw_ctx: rawptr) {
				ctx := cast(^Compat_Context)raw_ctx
				check_expr_compat(ctx, expr)
			},
			ctx = rawptr(&ctx),
		}
		core.walk_all_stmts(&visitor, module.body)
	}

	// §19.3: Unused/missing dependencies
	if len(deps) > 0 {
		check_dependencies(bind_result, deps, file_path, diagnostics, allocator)
	}

}

// ==================== §19.2: Version Compatibility ====================

check_stmt_compat :: proc(ctx: ^Compat_Context, stmt: parser.Stmt) {
	#partial switch s in stmt {
	case ^parser.Match_Stmt:
		emit_compat(ctx, s.loc, "match/case", {3, 10})

	case ^parser.Type_Alias_Stmt:
		emit_compat(ctx, s.loc, "type alias statement", {3, 12})

	case ^parser.Ann_Assign:
		check_annotation_compat(ctx, s.annotation)

	case ^parser.Func_Def:
		// Check return annotation
		check_annotation_compat(ctx, s.returns)
		// Check arg annotations
		for &a in s.args.args { check_annotation_compat(ctx, a.annotation) }
		for &a in s.args.posonlyargs { check_annotation_compat(ctx, a.annotation) }
		for &a in s.args.kwonlyargs { check_annotation_compat(ctx, a.annotation) }

	case ^parser.Async_Func_Def:
		check_annotation_compat(ctx, s.returns)
		for &a in s.args.args { check_annotation_compat(ctx, a.annotation) }
		for &a in s.args.posonlyargs { check_annotation_compat(ctx, a.annotation) }
		for &a in s.args.kwonlyargs { check_annotation_compat(ctx, a.annotation) }
	}
}

check_expr_compat :: proc(ctx: ^Compat_Context, expr: parser.Expr) {
	#partial switch e in expr {
	case ^parser.Named_Expr:
		emit_compat(ctx, e.loc, "walrus operator (:=)", {3, 8})

	case ^parser.Joined_Str:
		emit_compat(ctx, e.loc, "f-string", {3, 6})
	}
}

// Check annotation expressions for X | Y union syntax (3.10+).
// Called only on known annotation positions, not arbitrary expressions.
check_annotation_compat :: proc(ctx: ^Compat_Context, expr: parser.Expr) {
	if expr == nil { return }
	if e, ok := expr.(^parser.Bin_Op_Expr); ok {
		if e.op == .Bit_Or {
			emit_compat(ctx, e.loc, "X | Y union syntax in annotation", {3, 10})
			// Recurse into nested unions: int | str | None
			check_annotation_compat(ctx, e.left)
			check_annotation_compat(ctx, e.right)
		}
	}
}

emit_compat :: proc(ctx: ^Compat_Context, loc: parser.Src_Loc, feature: string, required: Py_Version) {
	if version_ge(ctx.min_version, required) { return }

	append(ctx.diagnostics, core.Diagnostic{
		severity = .Error,
		location = core.Location{
			file   = ctx.file_path,
			line   = int(loc.line),
			column = int(loc.col),
		},
		what = fmt.tprintf("%s requires Python %d.%d+, but requires-python declares %d.%d+",
			feature, required.major, required.minor, ctx.min_version.major, ctx.min_version.minor),
		why  = "code uses syntax not available in the declared minimum Python version",
		fix  = fmt.tprintf("update requires-python to \">=%d.%d\" or avoid this syntax", required.major, required.minor),
		code = "COMPAT001",
	})
}

version_ge :: proc(have, need: Py_Version) -> bool {
	if have.major > need.major { return true }
	if have.major == need.major && have.minor >= need.minor { return true }
	return false
}

// ==================== §19.3: Dependency Checking ====================

check_dependencies :: proc(
	bind_result: ^binder.Bind_Result,
	deps: map[string]bool,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	// Collect imported module names
	imported := make(map[string]bool, 16, allocator)
	for &imp in bind_result.imports {
		top_module := imp.module_name
		// Extract top-level: "os.path" → "os"
		for i in 0..<len(top_module) {
			if top_module[i] == '.' {
				top_module = top_module[:i]
				break
			}
		}
		imported[top_module] = true
	}

	// DEP001: declared but never imported
	for dep in deps {
		pkg_name := dep_to_import_name(dep)
		if pkg_name not_in imported {
			append(diagnostics, core.Diagnostic{
				severity = .Warning,
				location = core.Location{
					file   = file_path,
					line   = 1,
					column = 0,
				},
				what = fmt.tprintf("dependency \"%s\" is declared but never imported", dep),
				why  = "unused dependencies increase install time and attack surface",
				fix  = fmt.tprintf("remove \"%s\" from [dependencies] in mimir.toml", dep),
				code = "DEP001",
			})
		}
	}

	// DEP002: imported but not declared (excluding stdlib)
	for mod_name in imported {
		if is_stdlib_module(mod_name) { continue }
		if mod_name == "mimir" { continue } // virtual modules

		found := false
		for dep in deps {
			if dep_to_import_name(dep) == mod_name {
				found = true
				break
			}
		}
		if !found {
			append(diagnostics, core.Diagnostic{
				severity = .Warning,
				location = core.Location{
					file   = file_path,
					line   = 1,
					column = 0,
				},
				what = fmt.tprintf("module \"%s\" is imported but not declared in [dependencies]", mod_name),
				why  = "undeclared dependencies may not be installed in deployment",
				fix  = fmt.tprintf("run: mimir add %s", import_to_dep_name(mod_name)),
				code = "DEP002",
			})
		}
	}
}

// Map package name → import name (for common mismatches)
dep_to_import_name :: proc(dep: string) -> string {
	// Common package→import name mismatches
	if dep == "Pillow" || dep == "pillow" { return "PIL" }
	if dep == "opencv-python" || dep == "opencv-python-headless" { return "cv2" }
	if dep == "scikit-learn" { return "sklearn" }
	if dep == "python-dateutil" { return "dateutil" }
	if dep == "PyYAML" || dep == "pyyaml" { return "yaml" }
	if dep == "beautifulsoup4" { return "bs4" }
	if dep == "python-dotenv" { return "dotenv" }
	if dep == "attrs" { return "attr" }

	// Default: lowercase, replace hyphens with underscores
	lower := strings.to_lower(dep, context.temp_allocator)
	result, _ := strings.replace_all(lower, "-", "_", context.temp_allocator)
	return result
}

import_to_dep_name :: proc(mod_name: string) -> string {
	// Reverse of common mismatches
	if mod_name == "PIL" { return "Pillow" }
	if mod_name == "cv2" { return "opencv-python" }
	if mod_name == "sklearn" { return "scikit-learn" }
	if mod_name == "dateutil" { return "python-dateutil" }
	if mod_name == "yaml" { return "PyYAML" }
	if mod_name == "bs4" { return "beautifulsoup4" }
	if mod_name == "dotenv" { return "python-dotenv" }
	if mod_name == "attr" { return "attrs" }
	return mod_name
}

is_stdlib_module :: proc(name: string) -> bool {
	STDLIB :: [?]string{
		"abc", "aifc", "argparse", "array", "ast", "asynchat", "asyncio", "asyncore",
		"atexit", "base64", "bdb", "binascii", "binhex", "bisect", "builtins",
		"bz2", "calendar", "cgi", "cgitb", "chunk", "cmath", "cmd", "code",
		"codecs", "codeop", "collections", "colorsys", "compileall", "concurrent",
		"configparser", "contextlib", "contextvars", "copy", "copyreg", "cProfile",
		"crypt", "csv", "ctypes", "curses", "dataclasses", "datetime", "dbm",
		"decimal", "difflib", "dis", "distutils", "doctest", "email", "encodings",
		"enum", "errno", "faulthandler", "fcntl", "filecmp", "fileinput", "fnmatch",
		"formatter", "fractions", "ftplib", "functools", "gc", "getopt", "getpass",
		"gettext", "glob", "grp", "gzip", "hashlib", "heapq", "hmac", "html",
		"http", "idlelib", "imaplib", "imghdr", "imp", "importlib", "inspect",
		"io", "ipaddress", "itertools", "json", "keyword", "lib2to3", "linecache",
		"locale", "logging", "lzma", "mailbox", "mailcap", "marshal", "math",
		"mimetypes", "mmap", "modulefinder", "multiprocessing", "netrc", "nis",
		"nntplib", "numbers", "operator", "optparse", "os", "ossaudiodev",
		"pathlib", "pdb", "pickle", "pickletools", "pipes", "pkgutil", "platform",
		"plistlib", "poplib", "posix", "posixpath", "pprint", "profile", "pstats",
		"pty", "pwd", "py_compile", "pyclbr", "pydoc", "queue", "quopri",
		"random", "re", "readline", "reprlib", "resource", "rlcompleter", "runpy",
		"sched", "secrets", "select", "selectors", "shelve", "shlex", "shutil",
		"signal", "site", "smtpd", "smtplib", "sndhdr", "socket", "socketserver",
		"sqlite3", "ssl", "stat", "statistics", "string", "stringprep", "struct",
		"subprocess", "sunau", "symtable", "sys", "sysconfig", "syslog", "tabnanny",
		"tarfile", "telnetlib", "tempfile", "termios", "test", "textwrap", "threading",
		"time", "timeit", "tkinter", "token", "tokenize", "tomllib", "trace",
		"traceback", "tracemalloc", "tty", "turtle", "turtledemo", "types",
		"typing", "unicodedata", "unittest", "urllib", "uu", "uuid", "venv",
		"warnings", "wave", "weakref", "webbrowser", "winreg", "winsound",
		"wsgiref", "xdrlib", "xml", "xmlrpc", "zipapp", "zipfile", "zipimport",
		"zlib", "_thread",
	}

	for m in STDLIB {
		if m == name { return true }
	}
	return false
}

// ==================== Config Reading ====================

read_compat_config :: proc(start_dir: string, allocator: mem.Allocator) -> (config_path: string, min_version: Py_Version, deps: map[string]bool) {
	deps = make(map[string]bool, 8, allocator)

	// Walk up directories looking for mimir.toml
	dir := start_dir
	found_path := ""
	for {
		candidate := fmt.tprintf("%s/mimir.toml", dir)
		if os.is_file(candidate) {
			found_path = candidate
			break
		}
		// Go up one level
		parent := dir
		for i := len(dir) - 1; i >= 0; i -= 1 {
			if dir[i] == '/' {
				parent = dir[:i]
				break
			}
		}
		if parent == dir || len(parent) == 0 { break }
		dir = parent
	}
	if len(found_path) == 0 { return "", {}, deps }

	// Read file
	data, read_err := os.read_entire_file(found_path, allocator)
	if read_err != nil { return "", {}, deps }

	content := string(data)
	min_version = Py_Version{}

	// Simple line-by-line parsing for requires-python and [dependencies]
	in_deps := false
	in_project := false
	lines := strings.split(content, "\n", allocator)

	for line in lines {
		trimmed := strings.trim_space(line)

		// Section headers
		if strings.has_prefix(trimmed, "[") {
			in_deps = trimmed == "[dependencies]"
			in_project = trimmed == "[project]"
			continue
		}

		// requires-python in [project]
		if in_project && strings.has_prefix(trimmed, "requires-python") {
			eq := strings.index_byte(trimmed, '=')
			if eq >= 0 {
				val := strings.trim_space(trimmed[eq+1:])
				val = strings.trim(val, "\"'")
				min_version = parse_min_version(val)
			}
		}

		// Dependencies
		if in_deps && len(trimmed) > 0 && !strings.has_prefix(trimmed, "#") {
			eq := strings.index_byte(trimmed, '=')
			if eq > 0 {
				dep_name := strings.trim_space(trimmed[:eq])
				deps[dep_name] = true
			}
		}
	}

	return found_path, min_version, deps
}

parse_min_version :: proc(spec: string) -> Py_Version {
	// Parse ">=3.8" or ">=3.10" or "3.8"
	s := spec
	// Strip comparison operator
	if strings.has_prefix(s, ">=") { s = s[2:] }
	else if strings.has_prefix(s, ">") { s = s[1:] }
	else if strings.has_prefix(s, "==") { s = s[2:] }

	s = strings.trim_space(s)

	dot := strings.index_byte(s, '.')
	if dot < 0 { return {} }

	major, major_ok := strconv.parse_int(s[:dot])
	if !major_ok { return {} }

	minor_str := s[dot+1:]
	// Handle "3.10.1" — take just minor
	dot2 := strings.index_byte(minor_str, '.')
	if dot2 >= 0 { minor_str = minor_str[:dot2] }

	minor, minor_ok := strconv.parse_int(minor_str)
	if !minor_ok { return {} }

	return Py_Version{major = major, minor = minor}
}

// ==================== §19.1: Deprecated Library API (COMPAT002) ====================

Deprecated_API :: struct {
	module:      string,  // import module name
	attr:        string,  // attribute name (empty = entire module)
	replacement: string,  // suggested replacement
	version:     string,  // version where deprecated/removed
}

DEPRECATED_APIS :: [?]Deprecated_API{
	// distutils removed in Python 3.12
	{"distutils",        "",                  "setuptools",                     "removed in 3.12"},
	// collections direct access deprecated since 3.3, removed 3.10
	{"collections",      "MutableMapping",    "collections.abc.MutableMapping", "moved in 3.3"},
	{"collections",      "MutableSequence",   "collections.abc.MutableSequence","moved in 3.3"},
	{"collections",      "MutableSet",        "collections.abc.MutableSet",     "moved in 3.3"},
	{"collections",      "Mapping",           "collections.abc.Mapping",        "moved in 3.3"},
	{"collections",      "Sequence",          "collections.abc.Sequence",       "moved in 3.3"},
	{"collections",      "Iterable",          "collections.abc.Iterable",       "moved in 3.3"},
	{"collections",      "Iterator",          "collections.abc.Iterator",       "moved in 3.3"},
	{"collections",      "Callable",          "collections.abc.Callable",       "moved in 3.3"},
	// imp module deprecated since 3.4
	{"imp",              "",                  "importlib",                      "deprecated since 3.4"},
	// pkg_resources → importlib.metadata
	{"pkg_resources",    "",                  "importlib.metadata",             "deprecated"},
	// cgi module deprecated in 3.11, removed in 3.13
	{"cgi",              "",                  "email.message or urllib.parse",  "removed in 3.13"},
	// pipes module deprecated
	{"pipes",            "",                  "subprocess",                     "removed in 3.13"},
	// asynchat/asyncore deprecated since 3.6
	{"asynchat",         "",                  "asyncio",                        "removed in 3.12"},
	{"asyncore",         "",                  "asyncio",                        "removed in 3.12"},
}

check_deprecated_apis :: proc(
	module: ^parser.Module,
	bind_result: ^binder.Bind_Result,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	// Build import map: local_name → module_name
	import_map := make(map[string]string, 16, allocator)
	for &imp in bind_result.imports {
		// Whole module import
		top := imp.module_name
		for i in 0..<len(top) {
			if top[i] == '.' { top = top[:i]; break }
		}
		import_map[top] = imp.module_name
	}

	// Check whole-module deprecated imports (e.g., import distutils)
	for stmt in module.body {
		#partial switch s in stmt {
		case ^parser.Import_Stmt:
			for alias in s.names {
				for dep in DEPRECATED_APIS {
					if len(dep.attr) == 0 && alias.name == dep.module {
						append(diagnostics, core.Diagnostic{
							severity = .Warning,
							location = core.Location{
								file   = file_path,
								line   = int(s.loc.line),
								column = int(s.loc.col),
							},
							code = "COMPAT002",
							what = fmt.tprintf("deprecated module '%s' (%s)", dep.module, dep.version),
							why  = fmt.tprintf("'%s' is deprecated and may be removed in future Python versions", dep.module),
							fix  = fmt.tprintf("use '%s' instead", dep.replacement),
						})
					}
				}
			}
		case ^parser.Import_From:
			if s.level > 0 { continue }
			for dep in DEPRECATED_APIS {
				// Whole-module deprecation: from distutils import ...
				if len(dep.attr) == 0 && s.module == dep.module {
					append(diagnostics, core.Diagnostic{
						severity = .Warning,
						location = core.Location{
							file   = file_path,
							line   = int(s.loc.line),
							column = int(s.loc.col),
						},
						code = "COMPAT002",
						what = fmt.tprintf("deprecated module '%s' (%s)", dep.module, dep.version),
						why  = fmt.tprintf("'%s' is deprecated and may be removed in future Python versions", dep.module),
						fix  = fmt.tprintf("use '%s' instead", dep.replacement),
					})
					break
				}
				// Specific attribute deprecation: from collections import MutableMapping
				if dep.module == s.module && len(dep.attr) > 0 {
					for alias in s.names {
						if alias.name == dep.attr {
							append(diagnostics, core.Diagnostic{
								severity = .Warning,
								location = core.Location{
									file   = file_path,
									line   = int(s.loc.line),
									column = int(s.loc.col),
								},
								code = "COMPAT002",
								what = fmt.tprintf("deprecated: '%s.%s' (%s)", dep.module, dep.attr, dep.version),
								why  = fmt.tprintf("'%s.%s' has been moved/deprecated", dep.module, dep.attr),
								fix  = fmt.tprintf("use '%s' instead", dep.replacement),
							})
						}
					}
				}
			}
		}
	}
}
