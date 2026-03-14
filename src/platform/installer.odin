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
	// Reject dependency specs that look like flags (prevents pip flag injection)
	if len(dep.raw) > 0 && dep.raw[0] == '-' {
		return Platform_Error_Data{msg = fmt.tprintf("invalid dependency spec '%s': must not start with '-'", dep.raw)}
	}

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
		if found && len(dep.constraint) == 0 {
			// Only trust cache for unconstrained deps — constrained deps
			// need version verification we can't do yet, so reinstall
			append(&paths, dir)
			continue
		}
		if found && len(dep.constraint) > 0 {
			// Have a cached version but can't verify constraint — reinstall
			// TODO: parse installed version from METADATA and compare
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

// Install a single package at an exact version with --no-deps.
// Used by lockfile install — all transitive deps are already resolved.
install_package_pinned :: proc(
	python: string,
	name, version: string,
	target_dir: string,
	allocator: mem.Allocator,
) -> Platform_Error {
	temp_dir := strings.concatenate({target_dir, ".tmp"}, allocator)

	// Clean up any previous partial install
	if os.exists(temp_dir) {
		os.remove_all(temp_dir)
	}

	// pip install --target <temp> --no-deps --quiet <name>==<version>
	pinned := strings.concatenate({name, "==", version}, allocator)
	state, _, stderr, exec_err := os.process_exec({
		command = {python, "-m", "pip", "install", "--target", temp_dir, "--no-deps", "--quiet", pinned},
	}, allocator)
	if exec_err != nil {
		if os.exists(temp_dir) { os.remove_all(temp_dir) }
		return Platform_Error_Data{msg = fmt.tprintf("failed to run pip for '%s': %v", name, exec_err)}
	}

	if state.exit_code != 0 {
		msg := string(stderr) if len(stderr) > 0 else "unknown error"
		if os.exists(temp_dir) { os.remove_all(temp_dir) }
		return Platform_Error_Data{msg = fmt.tprintf("pip install '%s==%s' failed: %s", name, version, strings.trim_space(msg))}
	}

	// Ensure parent directory exists (packages/<name>/)
	parent := parent_dir(target_dir)
	os.make_directory_all(parent)

	// Atomic: rename temp → target
	if os.exists(target_dir) {
		os.remove_all(target_dir)
	}
	rename_err := os.rename(temp_dir, target_dir)
	if rename_err != nil {
		if os.exists(temp_dir) { os.remove_all(temp_dir) }
		return Platform_Error_Data{msg = fmt.tprintf("failed to move installed packages for '%s': %v", name, rename_err)}
	}

	return nil
}

// Install all packages from a lockfile into the cache.
// Uses CAS (content-addressed storage) if hashes are present, falls back to versioned dirs.
// Populates hashes on lockfile entries for newly installed packages.
install_from_lockfile :: proc(
	python: string,
	lf: ^Lockfile,
	cache: ^Cache,
	allocator: mem.Allocator,
) -> Platform_Error {
	installed := 0
	skipped := 0

	for &pkg in lf.packages {
		// Try CAS path first (Layer 4)
		cas_path, cas_key, cas_found := find_cas_package(cache, pkg.name, pkg.version)
		if cas_found {
			pkg.hash = cas_key
			skipped += 1
			continue
		}

		// Fall back to legacy versioned dir
		_, legacy_found := find_package_version(cache, pkg.name, pkg.version)
		if legacy_found {
			// Compute hash for legacy package (for import map generation)
			pkg.hash = cas_hash(pkg.name, pkg.version, allocator)
			skipped += 1
			continue
		}

		// Install to CAS dir
		target, key := cas_target_dir(cache, pkg.name, pkg.version)
		fmt.printfln("  installing %s==%s...", pkg.name, pkg.version)
		install_err := install_package_pinned(python, pkg.name, pkg.version, target, allocator)
		if install_err != nil {
			return install_err
		}
		pkg.hash = key
		installed += 1
	}

	fmt.printfln("  %d installed, %d already cached", installed, skipped)
	return nil
}

// Check if pip is available for the given Python interpreter.
detect_pip :: proc(python: string, allocator: mem.Allocator) -> bool {
	state, _, _, exec_err := os.process_exec({
		command = {python, "-m", "pip", "--version"},
	}, allocator)
	if exec_err != nil { return false }
	return state.exit_code == 0
}
