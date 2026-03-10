package platform

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// Pip-delegated package installer.
// Uses pip install --target to populate the global cache.

// Install a single package via pip into the target directory.
// Uses atomic install: pip installs to temp dir, then rename to target.
install_package :: proc(python: string, dep: Dep_Spec, target_dir: string, allocator: mem.Allocator) -> Platform_Error {
	temp_dir := strings.concatenate({target_dir, ".tmp"}, allocator)

	// Clean up any previous partial install
	if os.exists(temp_dir) {
		os.remove_all(temp_dir)
	}

	// Run pip install --target <temp_dir> --quiet "<dep.raw>"
	state, _, stderr, exec_err := os.process_exec({
		command = {python, "-m", "pip", "install", "--target", temp_dir, "--quiet", dep.raw},
	}, allocator)
	if exec_err != nil {
		// Clean up temp dir on failure
		if os.exists(temp_dir) { os.remove_all(temp_dir) }
		return Platform_Error_Data{msg = fmt.tprintf("failed to run pip for '%s': %v", dep.name, exec_err)}
	}

	if state.exit_code != 0 {
		msg := string(stderr) if len(stderr) > 0 else "unknown error"
		if os.exists(temp_dir) { os.remove_all(temp_dir) }
		return Platform_Error_Data{msg = fmt.tprintf("pip install '%s' failed: %s", dep.raw, strings.trim_space(msg))}
	}

	// Atomic: rename temp → target
	if os.exists(target_dir) {
		os.remove_all(target_dir)
	}
	rename_err := os.rename(temp_dir, target_dir)
	if rename_err != nil {
		if os.exists(temp_dir) { os.remove_all(temp_dir) }
		return Platform_Error_Data{msg = fmt.tprintf("failed to move installed packages for '%s': %v", dep.name, rename_err)}
	}

	return nil
}

// Ensure all dependencies are installed. Returns list of package directories for PYTHONPATH.
ensure_dependencies :: proc(
	python: string,
	deps: []Dep_Spec,
	cache: ^Cache,
	allocator: mem.Allocator,
) -> (paths: [dynamic]string, err: Platform_Error) {
	paths = make([dynamic]string, 0, len(deps), allocator)

	for dep in deps {
		dir, found := find_package(cache, dep.name)
		if found {
			append(&paths, dir)
			continue
		}

		// Install missing package
		target := package_dir(cache, dep.name)
		fmt.printfln("  installing %s...", dep.raw)
		install_err := install_package(python, dep, target, allocator)
		if install_err != nil {
			return paths, install_err
		}
		append(&paths, target)
	}

	return paths, nil
}

// Check if pip is available for the given Python interpreter.
detect_pip :: proc(python: string, allocator: mem.Allocator) -> bool {
	state, _, _, exec_err := os.process_exec({
		command = {python, "-m", "pip", "--version"},
	}, allocator)
	if exec_err != nil { return false }
	return state.exit_code == 0
}
