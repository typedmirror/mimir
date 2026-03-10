package platform

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// Orchestrates mimir run: metadata → deps → spawn.

Run_Config :: struct {
	script:         string,    // path to .py file
	python_version: string,    // "" for default
	check_first:    bool,      // --check flag
	skip_deps:      bool,      // --no-deps flag
	script_args:    []string,  // args after --
}

Platform_Error :: union {
	Platform_Error_Data,
}

Platform_Error_Data :: struct {
	msg: string,
}

error_msg :: proc(err: Platform_Error) -> string {
	if data, ok := err.(Platform_Error_Data); ok {
		return data.msg
	}
	return "unknown error"
}

// Main orchestration — the 10-step flow from the plan.
// Returns process exit code.
run :: proc(config: Run_Config, allocator: mem.Allocator) -> int {
	// 1. Verify script exists
	if !os.exists(config.script) {
		fmt.eprintfln("mimir run: script '%s' not found", config.script)
		return 1
	}
	if !os.is_file(config.script) {
		fmt.eprintfln("mimir run: '%s' is not a file", config.script)
		return 1
	}

	// 2. Parse PEP 723 metadata
	metadata, meta_err := parse_script_metadata(config.script, allocator)
	if meta_err != nil {
		fmt.eprintfln("mimir run: %s", error_msg(meta_err))
		return 1
	}

	// 3. Determine Python version
	py_version := config.python_version
	if py_version == "" && metadata.python_version != "" {
		// Extract version from constraint like ">=3.12"
		py_version = _extract_version(metadata.python_version)
	}

	// 4. Find Python interpreter
	python, py_ok := find_python(py_version, allocator)
	if !py_ok {
		if py_version != "" {
			fmt.eprintfln("mimir run: python%s not found on PATH", py_version)
		} else {
			fmt.eprintfln("mimir run: python3 not found on PATH")
		}
		return 1
	}

	// 5. Resolve dependencies (unless --no-deps)
	package_paths: [dynamic]string
	if !config.skip_deps && len(metadata.dependencies) > 0 {
		// Check pip availability
		if !detect_pip(python, allocator) {
			fmt.eprintfln("mimir run: pip not available for '%s'", python)
			fmt.eprintfln("  install pip: %s -m ensurepip", python)
			return 1
		}

		cache, cache_err := init_cache(allocator)
		if cache_err != nil {
			fmt.eprintfln("mimir run: %s", error_msg(cache_err))
			return 1
		}

		paths, dep_err := ensure_dependencies(python, metadata.dependencies[:], &cache, allocator)
		if dep_err != nil {
			fmt.eprintfln("mimir run: %s", error_msg(dep_err))
			return 1
		}
		package_paths = paths
	}

	// 6. Build PYTHONPATH
	pythonpath := build_pythonpath(package_paths[:], config.script, allocator)

	// 7. Set PYTHONPATH in current process (inherited by child)
	if pythonpath != "" {
		set_err := os.set_env("PYTHONPATH", pythonpath)
		if set_err != nil {
			fmt.eprintfln("mimir run: failed to set PYTHONPATH: %v", set_err)
			return 1
		}
	}

	// 8. Spawn Python process
	return spawn_python(python, config.script, config.script_args)
}

// Find a Python interpreter on PATH.
// Tries: python<version>, python3, python (in that order).
find_python :: proc(version: string, allocator: mem.Allocator) -> (path: string, ok: bool) {
	candidates: [dynamic]string
	candidates.allocator = allocator

	if version != "" {
		append(&candidates, strings.concatenate({"python", version}, allocator))
	}
	append(&candidates, "python3")
	append(&candidates, "python")

	for candidate in candidates {
		// Try running --version to verify it works
		state, _, _, exec_err := os.process_exec({
			command = {candidate, "--version"},
		}, allocator)
		if exec_err == nil && state.exit_code == 0 {
			return candidate, true
		}
	}

	return "", false
}

// Build PYTHONPATH from package directories + script's parent directory.
build_pythonpath :: proc(package_paths: []string, script: string, allocator: mem.Allocator) -> string {
	parts := make([dynamic]string, 0, len(package_paths) + 1, allocator)

	// Package dirs first (take precedence)
	for p in package_paths {
		append(&parts, p)
	}

	// Add script's parent directory
	project_root := _parent_dir(script)
	if project_root != "" {
		append(&parts, project_root)
	}

	if len(parts) == 0 {
		return ""
	}

	return strings.join(parts[:], ":", allocator)
}

// Spawn Python with script and args, inheriting terminal I/O.
// Returns process exit code.
spawn_python :: proc(python: string, script: string, args: []string) -> int {
	// Build command: python script.py [args...]
	cmd := make([dynamic]string, 0, 2 + len(args), context.temp_allocator)
	append(&cmd, python)
	append(&cmd, script)
	for arg in args {
		append(&cmd, arg)
	}

	// Start process, inheriting stdin/stdout/stderr
	process, proc_err := os.process_start({
		command = cmd[:],
		stdin   = os.stdin,
		stdout  = os.stdout,
		stderr  = os.stderr,
	})
	if proc_err != nil {
		fmt.eprintfln("mimir run: failed to start '%s': %v", python, proc_err)
		return 1
	}

	// Wait for completion
	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		fmt.eprintfln("mimir run: error waiting for process: %v", wait_err)
		return 1
	}

	return state.exit_code
}

// Extract version number from a constraint like ">=3.12" → "3.12"
@(private = "file")
_extract_version :: proc(constraint: string) -> string {
	s := constraint
	// Strip operator prefix
	for s != "" && (s[0] == '>' || s[0] == '<' || s[0] == '=' || s[0] == '~' || s[0] == '!') {
		s = s[1:]
	}
	return strings.trim_space(s)
}

// Get parent directory of a file path.
@(private = "file")
_parent_dir :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' {
			return path[:i] if i > 0 else "/"
		}
	}
	return "."
}
