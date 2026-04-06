package platform

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// Typeshed stdlib stub manager — download, extract, and resolve .pyi stubs.
// Layout: ~/.mimir/stubs/stdlib/<module>.pyi or <module>/__init__.pyi
// Source: typeshed GitHub repo (stdlib/ subtree).

TYPESHED_URL :: "https://github.com/python/typeshed/archive/refs/heads/main.tar.gz"

// Note: is_stdlib_module is defined in deps_analysis.odin (same package)
// with a comprehensive list of ~180 stdlib modules.

// Base directory for stubs: ~/.mimir/stubs/
stubs_base_dir :: proc(allocator: mem.Allocator) -> (string, Platform_Error) {
	home, home_err := os.user_home_dir(allocator)
	if home_err != nil {
		return "", Platform_Error_Data{msg = "cannot determine home directory"}
	}
	return strings.concatenate({home, "/.mimir/stubs"}, allocator), nil
}

// Check if typeshed stdlib stubs are available.
stubs_available :: proc(allocator: mem.Allocator) -> bool {
	base, err := stubs_base_dir(allocator)
	if err != nil { return false }
	stdlib_dir := strings.concatenate({base, "/stdlib"}, allocator)
	return os.is_directory(stdlib_dir)
}

// Download and extract typeshed stdlib stubs to ~/.mimir/stubs/stdlib/.
fetch_typeshed :: proc(allocator: mem.Allocator) -> Platform_Error {
	base, base_err := stubs_base_dir(allocator)
	if base_err != nil { return base_err }

	stdlib_dir := strings.concatenate({base, "/stdlib"}, allocator)

	// Create directory tree
	mkdir_err := os.make_directory_all(base)
	if mkdir_err != nil && mkdir_err != .Exist {
		return Platform_Error_Data{
			msg = fmt.aprintf("cannot create stubs directory '%s': %v", base, mkdir_err, allocator = allocator),
		}
	}

	// Download typeshed tarball
	tmp_dir, tmp_err := os.temp_directory(allocator)
	if tmp_err != nil { tmp_dir = "/tmp" }
	tarball := strings.concatenate({tmp_dir, "/mimir-typeshed.tar.gz"}, allocator)

	fmt.println("  downloading typeshed stdlib stubs...")

	curl_state, _, curl_stderr, curl_err := os.process_exec({
		command = {"curl", "-fSL", "-o", tarball, TYPESHED_URL},
	}, allocator)
	if curl_err != nil {
		return Platform_Error_Data{
			msg = fmt.aprintf("failed to start curl: %v", curl_err, allocator = allocator),
		}
	}
	if curl_state.exit_code != 0 {
		return Platform_Error_Data{
			msg = fmt.aprintf("download failed (curl exit %d): %s",
				curl_state.exit_code, string(curl_stderr), allocator = allocator),
		}
	}

	// Remove old stubs if present
	if os.is_directory(stdlib_dir) {
		os.remove_all(stdlib_dir)
	}

	// Extract only the stdlib/ subtree from the tarball
	// Tarball structure: typeshed-main/stdlib/...
	// --strip-components=1 removes "typeshed-main/" prefix
	// We extract typeshed-main/stdlib/ → stubs/stdlib/
	extract_dir := base
	fmt.println("  extracting stdlib stubs...")

	tar_state, _, tar_stderr, tar_err := os.process_exec({
		command = {"tar", "xf", tarball, "-C", extract_dir,
			"--strip-components=1", "typeshed-main/stdlib"},
	}, allocator)
	if tar_err != nil {
		os.remove(tarball)
		return Platform_Error_Data{
			msg = fmt.aprintf("failed to run tar: %v", tar_err, allocator = allocator),
		}
	}
	if tar_state.exit_code != 0 {
		os.remove(tarball)
		return Platform_Error_Data{
			msg = fmt.aprintf("extraction failed: %s", string(tar_stderr), allocator = allocator),
		}
	}

	// Clean up tarball
	os.remove(tarball)

	// Write version marker
	version_file := strings.concatenate({base, "/version"}, allocator)
	_ = os.write_entire_file(version_file, transmute([]u8)string("typeshed-main"))

	if os.is_directory(stdlib_dir) {
		fmt.println("  typeshed stdlib stubs installed successfully")
		return nil
	}

	return Platform_Error_Data{msg = "extraction completed but stdlib directory not found"}
}

// Resolve a stdlib module name to a .pyi stub file path.
// Returns the file path and whether it was found.
// Priority: <module>.pyi > <module>/__init__.pyi
resolve_stdlib_stub :: proc(
	module_name: string,
	stubs_dir: string,
	allocator: mem.Allocator,
) -> (file_path: string, found: bool) {
	if len(stubs_dir) == 0 { return "", false }

	stdlib_dir := strings.concatenate({stubs_dir, "/stdlib"}, allocator)

	// Split on first dot: "os.path" → top="os", sub="path"
	top := module_name
	sub_path := ""
	for i := 0; i < len(module_name); i += 1 {
		if module_name[i] == '.' {
			top = module_name[:i]
			sub_path = module_name[i+1:]
			break
		}
	}

	if len(sub_path) == 0 {
		// Simple module: re.pyi or os/__init__.pyi
		pyi := strings.concatenate({stdlib_dir, "/", top, ".pyi"}, allocator)
		if os.is_file(pyi) { return pyi, true }

		init_pyi := strings.concatenate({stdlib_dir, "/", top, "/__init__.pyi"}, allocator)
		if os.is_file(init_pyi) { return init_pyi, true }

		return "", false
	}

	// Sub-module: os.path → os/path.pyi or os/path/__init__.pyi
	// Convert dots to slashes
	buf := make([dynamic]u8, 0, len(sub_path), allocator)
	for c in sub_path {
		if c == '.' {
			append(&buf, '/')
		} else {
			append(&buf, u8(c))
		}
	}
	sub_file := string(buf[:])

	pyi := strings.concatenate({stdlib_dir, "/", top, "/", sub_file, ".pyi"}, allocator)
	if os.is_file(pyi) { return pyi, true }

	init_pyi := strings.concatenate({stdlib_dir, "/", top, "/", sub_file, "/__init__.pyi"}, allocator)
	if os.is_file(init_pyi) { return init_pyi, true }

	return "", false
}
