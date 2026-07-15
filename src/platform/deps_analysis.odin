package platform

import "core:fmt"
import "core:mem"
import "core:strings"

// Dependency intelligence analysis.
// Ghost dependency detection (DEP001) and usage analysis.

Dep_Finding :: struct {
	code:        string,
	module_name: string,
	message:     string,
	file:        string,
	line:        int,
}

// Analyze imports against declared dependencies.
// imports: list of (module_name, file, line) from binder.
// direct_deps: package names from mimir.toml.
// all_deps: package names from mimir.lock (includes transitive).
// Returns findings for ghost deps (DEP001) and missing deps (DEP002).
analyze_deps :: proc(
	imports: []Import_Info,
	direct_deps: []string,
	all_deps: []string,
	allocator: mem.Allocator,
) -> [dynamic]Dep_Finding {
	findings := make([dynamic]Dep_Finding, 0, 8, allocator)

	// Build lookup sets
	direct_set := make(map[string]bool, len(direct_deps), allocator)
	for dep in direct_deps {
		direct_set[normalize_pkg_name(dep)] = true
	}

	all_set := make(map[string]bool, len(all_deps), allocator)
	for dep in all_deps {
		all_set[normalize_pkg_name(dep)] = true
	}

	// Track which modules we've already reported (dedup)
	reported := make(map[string]bool, 16, allocator)

	for imp in imports {
		// Skip relative imports (level > 0)
		if imp.level > 0 { continue }

		// Extract top-level package name (e.g., "flask" from "flask.views")
		top := top_level_module(imp.module_name)
		if len(top) == 0 { continue }

		// Skip stdlib modules
		if is_stdlib_module(top) { continue }

		// Skip mimir virtual modules
		if strings.has_prefix(top, "mimir") { continue }

		// Skip already reported
		if top in reported { continue }

		norm := normalize_pkg_name(top)

		if norm in direct_set {
			// Declared direct dep — all good
			continue
		}

		if norm in all_set {
			// Transitive dep used directly — ghost dependency
			reported[top] = true
			append(&findings, Dep_Finding{
				code        = "DEP001",
				module_name = top,
				message     = fmt.tprintf(
					"'%s' is a transitive dependency used directly — add it to [dependencies] in mimir.toml",
					top,
				),
				file = imp.file,
				line = imp.line,
			})
		}
		// Note: we don't flag DEP002 (missing dep) here because the module might
		// be installed outside mimir's management (system packages, local modules).
		// DEP002 would require import resolution to confirm the module is truly missing.
	}

	return findings
}

// Import info extracted from binder results for deps analysis.
Import_Info :: struct {
	module_name: string,
	file:        string,
	line:        int,
	level:       int,
}

// Extract top-level module name from dotted path.
top_level_module :: proc(name: string) -> string {
	for i := 0; i < len(name); i += 1 {
		if name[i] == '.' {
			return name[:i]
		}
	}
	return name
}

// Normalize package name for comparison (lowercase, replace - with _).
normalize_pkg_name :: proc(name: string) -> string {
	// Most names are already normalized; avoid allocation for common case
	needs_norm := false
	for c in name {
		if c >= 'A' && c <= 'Z' || c == '-' {
			needs_norm = true
			break
		}
	}
	if !needs_norm { return name }

	buf := make([dynamic]u8, 0, len(name), context.temp_allocator)
	for c in name {
		if c >= 'A' && c <= 'Z' {
			append(&buf, u8(c - 'A' + 'a'))
		} else if c == '-' {
			append(&buf, '_')
		} else {
			append(&buf, u8(c))
		}
	}
	return string(buf[:])
}

// Python 3.12 stdlib modules (comprehensive list).
// Used to skip stdlib imports in ghost dependency detection.
@(private = "file")
STDLIB_MODULES := [?]string{
	// Core
	"__future__", // compiler-directive pseudo-module (PEP 236) — never a third-party dep
	"abc", "ast", "asyncio", "atexit", "builtins",
	// Collections & data
	"array", "bisect", "calendar", "collections", "copy", "csv",
	"dataclasses", "datetime", "decimal", "enum", "fractions",
	"functools", "graphlib", "heapq", "itertools",
	// Concurrency
	"concurrent", "multiprocessing", "queue", "sched",
	"select", "selectors", "signal", "subprocess", "threading",
	// Crypto & encoding
	"base64", "binascii", "codecs", "crypt", "hashlib", "hmac",
	"secrets", "uuid",
	// Debug & dev
	"bdb", "cProfile", "code", "compileall", "dis", "doctest",
	"faulthandler", "gc", "inspect", "pdb", "profile",
	"pstats", "trace", "traceback", "tracemalloc", "unittest",
	"warnings",
	// File & IO
	"configparser", "filecmp", "fileinput", "fnmatch", "glob",
	"io", "linecache", "mmap", "os", "pathlib", "shutil",
	"stat", "tempfile",
	// Formats
	"html", "json", "plistlib", "tomllib", "xml",
	// Import
	"importlib", "pkgutil", "zipimport",
	// Internet
	"cgi", "email", "ftplib", "http", "imaplib", "mailbox",
	"nntplib", "poplib", "smtplib", "socketserver", "urllib",
	"webbrowser", "wsgiref", "xmlrpc",
	// Logging
	"logging",
	// Math & numbers
	"cmath", "math", "numbers", "random", "statistics",
	// Network
	"ipaddress", "socket", "ssl",
	// OS & system
	"ctypes", "errno", "fcntl", "grp", "locale", "platform",
	"posixpath", "pwd", "resource", "rlcompleter", "sys",
	"sysconfig", "syslog", "termios", "tty",
	// Parsing
	"argparse", "getopt", "gettext", "optparse", "re",
	"string", "struct", "textwrap", "token", "tokenize",
	// Pickle & marshal
	"copyreg", "marshal", "pickle", "shelve",
	// Runtime
	"_thread", "contextvars", "operator", "types", "typing",
	"typing_extensions", "weakref",
	// Compression
	"bz2", "gzip", "lzma", "tarfile", "zipfile", "zlib",
	// Database
	"dbm", "sqlite3",
	// GUI
	"curses", "tkinter", "turtle",
	// Testing
	"pytest",
	// Other
	"cmd", "difflib", "getpass", "netrc", "pprint",
	"readline", "pty", "pipes", "site", "abc",
	"contextlib", "time", "timeit",
	// Undocumented / internal but commonly imported
	"_collections_abc", "_io", "posix", "nt",
}

@(private = "file")
_stdlib_set: map[string]bool
@(private = "file")
_stdlib_init: bool

is_stdlib_module :: proc(name: string) -> bool {
	if !_stdlib_init {
		for mod in STDLIB_MODULES {
			_stdlib_set[mod] = true
		}
		_stdlib_init = true
	}
	return name in _stdlib_set
}
