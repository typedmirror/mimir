package platform

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// Test runner — discovery, harness generation, execution, parsing, reporting.

Test_Config :: struct {
	target:      string,   // path to test dir or file
	filter:      string,   // -k filter pattern (substring match)
	check_first: bool,     // --check flag
	verbose:     bool,     // -v flag
}

Test_Status :: enum { Pass, Fail, Error, Skip }

Test_Result :: struct {
	name:      string,
	status:    Test_Status,
	duration:  f64,
	message:   string,
	traceback: string,
}

Test_Summary :: struct {
	results:  [dynamic]Test_Result,
	passed:   int,
	failed:   int,
	errors:   int,
	skipped:  int,
	duration: f64,
}

// Discover test files under root. Finds test_*.py and *_test.py files.
discover_test_files :: proc(root: string, allocator: mem.Allocator) -> ([]string, Platform_Error) {
	if strings.has_suffix(root, ".py") {
		if !os.exists(root) {
			return nil, Platform_Error_Data{msg = fmt.tprintf("test file '%s' not found", root)}
		}
		result := make([]string, 1, allocator)
		result[0] = strings.clone(root, allocator)
		return result, nil
	}

	if !os.is_directory(root) {
		return nil, Platform_Error_Data{msg = fmt.tprintf("'%s' is not a file or directory", root)}
	}

	files: [dynamic]string
	files.allocator = allocator
	_walk_test_dir(root, &files, allocator)

	slice.sort_by(files[:], proc(a, b: string) -> bool {
		return a < b
	})

	return files[:], nil
}

// Escape a string for embedding in a Python double-quoted string literal.
@(private = "file")
_escape_python_string :: proc(s: string, allocator: mem.Allocator) -> string {
	buf: [dynamic]byte
	buf.allocator = allocator
	for c in s {
		switch c {
		case '\\': append(&buf, '\\'); append(&buf, '\\')
		case '"':  append(&buf, '\\'); append(&buf, '"')
		case '\n': append(&buf, '\\'); append(&buf, 'n')
		case '\r': append(&buf, '\\'); append(&buf, 'r')
		case:      append(&buf, u8(c))
		}
	}
	return string(buf[:])
}

// Generate Python harness script with test file list and filter baked in.
generate_harness :: proc(test_files: []string, filter: string, allocator: mem.Allocator) -> string {
	parts: [dynamic]string
	parts.allocator = allocator

	// test_files = ["/path/to/test_foo.py", ...]
	append(&parts, "test_files = [")
	for file, idx in test_files {
		if idx > 0 {
			append(&parts, ", ")
		}
		append(&parts, "\"")
		append(&parts, _escape_python_string(file, allocator))
		append(&parts, "\"")
	}
	append(&parts, "]\n")

	// filter_str = "pattern"
	append(&parts, "filter_str = \"")
	append(&parts, _escape_python_string(filter, allocator))
	append(&parts, "\"\n")

	// Template body
	append(&parts, _HARNESS_TEMPLATE)

	return strings.concatenate(parts[:], allocator)
}

// Orchestrate test execution: discover → deps → harness → execute → parse.
run_tests :: proc(config: Test_Config, allocator: mem.Allocator) -> (Test_Summary, Platform_Error) {
	start := time.now()

	// 1. Discover test files
	test_files, discover_err := discover_test_files(config.target, allocator)
	if discover_err != nil {
		return {}, discover_err
	}

	if len(test_files) == 0 {
		return Test_Summary{
			results = make([dynamic]Test_Result, 0, allocator),
		}, nil
	}

	// 2. Find Python
	python, py_ok := find_python("", allocator)
	if !py_ok {
		return {}, Platform_Error_Data{msg = "python3 not found on PATH"}
	}

	// 3. Resolve project deps → PYTHONPATH
	package_paths := make([dynamic]string, 0, 8, allocator)
	cwd, cwd_err := os.get_working_directory(allocator)
	if cwd_err != nil { cwd = "." }

	config_path, config_found := find_config(cwd, allocator)
	if config_found {
		lock_path := lockfile_path(config_path, allocator)
		if os.is_file(lock_path) {
			lf, lf_err := read_lockfile(lock_path, allocator)
			if lf_err == nil {
				cache, cache_err := init_cache(allocator)
				if cache_err == nil {
					for pkg in lf.packages {
						dir, found := find_package_version(&cache, pkg.name, pkg.version)
						if found {
							append(&package_paths, dir)
						}
					}
				}
			}
		}
	}

	// Build PYTHONPATH: package dirs + test target dir + cwd
	pythonpath_parts := make([dynamic]string, 0, len(package_paths) + 2, allocator)
	for p in package_paths {
		append(&pythonpath_parts, p)
	}
	target_dir := config.target
	if strings.has_suffix(config.target, ".py") {
		target_dir = parent_dir(config.target)
	}
	append(&pythonpath_parts, target_dir)
	if target_dir != cwd {
		append(&pythonpath_parts, cwd)
	}
	pythonpath := strings.join(pythonpath_parts[:], ":", allocator)

	// 4. Generate harness
	harness := generate_harness(test_files, config.filter, allocator)

	// 5. Write harness to temp file
	tmp_dir, tmp_err := os.temp_directory(allocator)
	if tmp_err != nil { tmp_dir = "/tmp" }
	harness_path := strings.concatenate({tmp_dir, "/mimir_test_harness.py"}, allocator)

	write_err := os.write_entire_file(harness_path, transmute([]u8)harness)
	if write_err != nil {
		return {}, Platform_Error_Data{msg = fmt.tprintf("failed to write test harness: %v", write_err)}
	}
	defer {
		if os.exists(harness_path) {
			os.remove(harness_path)
		}
	}

	// 6. Set PYTHONPATH
	if pythonpath != "" {
		set_err := os.set_env("PYTHONPATH", pythonpath)
		if set_err != nil {
			return {}, Platform_Error_Data{msg = fmt.tprintf("failed to set PYTHONPATH: %v", set_err)}
		}
	}

	// 7. Execute harness — capture stdout (JSON results)
	state, stdout_bytes, stderr_bytes, exec_err := os.process_exec({
		command = {python, harness_path},
	}, allocator)

	if exec_err != nil {
		return {}, Platform_Error_Data{msg = fmt.tprintf("failed to execute tests: %v", exec_err)}
	}

	// If harness crashed with no output, report stderr
	if len(stdout_bytes) == 0 {
		stderr_str := string(stderr_bytes) if len(stderr_bytes) > 0 else "unknown error"
		return {}, Platform_Error_Data{msg = fmt.tprintf("test harness failed: %s", stderr_str)}
	}

	// 8. Parse JSON results
	summary, parse_err := _parse_results(stdout_bytes, allocator)
	if parse_err != nil {
		return {}, parse_err
	}

	summary.duration = time.duration_seconds(time.diff(start, time.now()))
	return summary, nil
}

// Print test results with formatting.
print_results :: proc(summary: ^Test_Summary, verbose: bool) {
	for result in summary.results {
		switch result.status {
		case .Pass:
			if verbose {
				fmt.printfln("  PASS  %s (%.3fs)", result.name, result.duration)
			}
		case .Fail:
			fmt.printfln("  FAIL  %s (%.3fs)", result.name, result.duration)
			if result.message != "" {
				fmt.printfln("        %s", result.message)
			}
			if result.traceback != "" {
				_print_indented(result.traceback)
			}
		case .Error:
			fmt.printfln("  ERROR %s (%.3fs)", result.name, result.duration)
			if result.message != "" {
				fmt.printfln("        %s", result.message)
			}
			if result.traceback != "" {
				_print_indented(result.traceback)
			}
		case .Skip:
			fmt.printfln("  SKIP  %s (%s)", result.name, result.message)
		}
	}

	// Summary line
	if summary.failed == 0 && summary.errors == 0 {
		fmt.printfln("mimir test: %d passed in %.2fs", summary.passed, summary.duration)
	} else {
		summary_parts: [dynamic]string
		summary_parts.allocator = context.temp_allocator
		if summary.passed > 0 {
			append(&summary_parts, fmt.tprintf("%d passed", summary.passed))
		}
		if summary.failed > 0 {
			append(&summary_parts, fmt.tprintf("%d failed", summary.failed))
		}
		if summary.errors > 0 {
			append(&summary_parts, fmt.tprintf("%d error", summary.errors))
		}
		if summary.skipped > 0 {
			append(&summary_parts, fmt.tprintf("%d skipped", summary.skipped))
		}
		fmt.printfln("mimir test: %s in %.2fs",
			strings.join(summary_parts[:], ", ", context.temp_allocator),
			summary.duration)
	}
}

// --- Private helpers ---

@(private = "file")
_walk_test_dir :: proc(dir: string, files: ^[dynamic]string, allocator: mem.Allocator) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	defer os.file_info_slice_delete(entries, context.temp_allocator)

	for entry in entries {
		if entry.type == .Directory {
			if _is_test_ignored(entry.name) do continue
			_walk_test_dir(entry.fullpath, files, allocator)
		} else if _is_test_file(entry.name) {
			append(files, strings.clone(entry.fullpath, allocator))
		}
	}
}

@(private = "file")
_is_test_ignored :: proc(name: string) -> bool {
	ignore_dirs := [?]string{
		".git", "__pycache__", ".venv", "venv",
		"node_modules", ".tox", ".mypy_cache",
		".pytest_cache", ".eggs", "build", "dist",
	}
	for ignore in ignore_dirs {
		if name == ignore do return true
	}
	return false
}

@(private = "file")
_is_test_file :: proc(name: string) -> bool {
	if !strings.has_suffix(name, ".py") do return false
	return strings.has_prefix(name, "test_") || strings.has_suffix(name, "_test.py")
}

@(private = "file")
_parse_results :: proc(data: []byte, allocator: mem.Allocator) -> (Test_Summary, Platform_Error) {
	parsed, json_err := json.parse(data, .JSON, true, allocator)
	if json_err != nil {
		return {}, Platform_Error_Data{msg = fmt.tprintf("failed to parse test results JSON: %v", json_err)}
	}

	root, root_ok := parsed.(json.Object)
	if !root_ok {
		return {}, Platform_Error_Data{msg = "test results: expected JSON object"}
	}

	results_val, has_results := root["results"]
	if !has_results {
		return {}, Platform_Error_Data{msg = "test results: missing 'results' array"}
	}

	results_arr, arr_ok := results_val.(json.Array)
	if !arr_ok {
		return {}, Platform_Error_Data{msg = "test results: 'results' is not an array"}
	}

	summary := Test_Summary{
		results = make([dynamic]Test_Result, 0, len(results_arr), allocator),
	}

	for item in results_arr {
		obj, obj_ok := item.(json.Object)
		if !obj_ok do continue

		result := Test_Result{}

		if v, has := obj["name"]; has {
			if s, ok := v.(json.String); ok { result.name = s }
		}
		if v, has := obj["status"]; has {
			if s, ok := v.(json.String); ok {
				switch s {
				case "pass":  result.status = .Pass
				case "fail":  result.status = .Fail
				case "error": result.status = .Error
				case "skip":  result.status = .Skip
				}
			}
		}
		if v, has := obj["time"]; has {
			#partial switch t in v {
			case json.Float:   result.duration = t
			case json.Integer: result.duration = f64(t)
			}
		}
		if v, has := obj["message"]; has {
			if s, ok := v.(json.String); ok { result.message = s }
		}
		if v, has := obj["traceback"]; has {
			if s, ok := v.(json.String); ok { result.traceback = s }
		}

		switch result.status {
		case .Pass:  summary.passed  += 1
		case .Fail:  summary.failed  += 1
		case .Error: summary.errors  += 1
		case .Skip:  summary.skipped += 1
		}

		append(&summary.results, result)
	}

	return summary, nil
}

@(private = "file")
_print_indented :: proc(text: string) {
	lines := strings.split(text, "\n", context.temp_allocator)
	for line in lines {
		if line != "" {
			fmt.printfln("        %s", line)
		}
	}
}

// Python harness template. test_files and filter_str are prepended dynamically.
@(private = "file")
_HARNESS_TEMPLATE :: `
import unittest, inspect, importlib, importlib.util, json, sys, os, time, traceback

class JsonResult(unittest.TestResult):
    def __init__(self):
        super().__init__()
        self.results = []
        self._starts = {}

    def startTest(self, test):
        super().startTest(test)
        self._starts[id(test)] = time.time()

    def addSuccess(self, test):
        super().addSuccess(test)
        self.results.append({
            "name": str(test), "status": "pass",
            "time": time.time() - self._starts[id(test)]
        })

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self.results.append({
            "name": str(test), "status": "fail",
            "time": time.time() - self._starts[id(test)],
            "message": str(err[1]),
            "traceback": self._exc_info_to_string(err, test)
        })

    def addError(self, test, err):
        super().addError(test, err)
        self.results.append({
            "name": str(test), "status": "error",
            "time": time.time() - self._starts[id(test)],
            "message": str(err[1]),
            "traceback": self._exc_info_to_string(err, test)
        })

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self.results.append({
            "name": str(test), "status": "skip",
            "time": time.time() - self._starts[id(test)],
            "message": reason
        })

suite = unittest.TestSuite()
loader = unittest.TestLoader()
import_errors = []

for fpath in test_files:
    modname = os.path.splitext(os.path.basename(fpath))[0]
    spec = importlib.util.spec_from_file_location(modname, fpath)
    try:
        mod = importlib.util.module_from_spec(spec)
        sys.modules[modname] = mod
        spec.loader.exec_module(mod)
    except Exception as e:
        import_errors.append({
            "name": f"{modname} (import)",
            "status": "error",
            "time": 0.0,
            "message": str(e),
            "traceback": traceback.format_exc()
        })
        continue

    for name, obj in inspect.getmembers(mod):
        if isinstance(obj, type) and issubclass(obj, unittest.TestCase) and obj is not unittest.TestCase:
            suite.addTests(loader.loadTestsFromTestCase(obj))

    for name, obj in inspect.getmembers(mod):
        if name.startswith("test_") and inspect.isfunction(obj):
            suite.addTest(unittest.FunctionTestCase(obj))

if filter_str:
    filtered = unittest.TestSuite()
    for test in suite:
        if filter_str in str(test):
            filtered.addTest(test)
    suite = filtered

result = JsonResult()
suite.run(result)

all_results = import_errors + result.results
print(json.dumps({"results": all_results, "total": len(all_results)}))
`
