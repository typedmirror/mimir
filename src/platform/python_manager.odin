package platform

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// Python version manager — install, list, remove managed Python interpreters.
// Downloads pre-built binaries from python-build-standalone (indygreg).
// Cache: ~/.mimir/pythons/{version}/python/bin/python3

Python_Release :: struct {
	version: string,
	tag:     string,
}

Python_Version :: struct {
	version: string,
	path:    string,
	active:  bool,
}

// Known-good releases from python-build-standalone.
// Future: fetch from GitHub API.
KNOWN_RELEASES := [5]Python_Release{
	{version = "3.13.0",  tag = "20241002"},
	{version = "3.12.7",  tag = "20241002"},
	{version = "3.11.10", tag = "20241002"},
	{version = "3.10.15", tag = "20241002"},
	{version = "3.9.20",  tag = "20241002"},
}

// Platform triple for python-build-standalone download URLs.
@(private = "file")
python_platform_triple :: proc() -> (string, bool) {
	when ODIN_OS == .Darwin {
		when ODIN_ARCH == .arm64 {
			return "aarch64-apple-darwin", true
		} else when ODIN_ARCH == .amd64 {
			return "x86_64-apple-darwin", true
		}
	} else when ODIN_OS == .Linux {
		when ODIN_ARCH == .amd64 {
			return "x86_64-unknown-linux-gnu", true
		} else when ODIN_ARCH == .arm64 {
			return "aarch64-unknown-linux-gnu", true
		}
	}
	return "", false
}

// Base directory for managed Python installations (~/.mimir/pythons).
pythons_base_dir :: proc(allocator: mem.Allocator) -> (string, Platform_Error) {
	home, home_err := os.user_home_dir(allocator)
	if home_err != nil {
		return "", Platform_Error_Data{msg = "cannot determine home directory"}
	}
	return strings.concatenate({home, "/.mimir/pythons"}, allocator), nil
}

// Full path to python3 binary for a given version.
python_version_bin :: proc(base: string, version: string, allocator: mem.Allocator) -> string {
	return strings.concatenate({base, "/", version, "/python/bin/python3"}, allocator)
}

// Find a release matching a version string.
// Supports exact match ("3.12.7") and prefix match ("3.12" → highest "3.12.x").
find_release :: proc(version: string) -> (Python_Release, bool) {
	// Exact match first
	for r in KNOWN_RELEASES {
		if r.version == version {
			return r, true
		}
	}
	// Prefix match: "3.12" matches "3.12.7" (first match is highest due to table order)
	for r in KNOWN_RELEASES {
		if len(r.version) > len(version) &&
		   strings.has_prefix(r.version, version) &&
		   r.version[len(version)] == '.' {
			return r, true
		}
	}
	return {}, false
}

// ============================================================
// Tier 1: Download + Install
// ============================================================

install_python :: proc(version: string, allocator: mem.Allocator) -> Platform_Error {
	release, found := find_release(version)
	if !found {
		return Platform_Error_Data{
			msg = fmt.aprintf("unknown Python version '%s'; run 'mimir python list --available'",
				version, allocator = allocator),
		}
	}

	triple, triple_ok := python_platform_triple()
	if !triple_ok {
		return Platform_Error_Data{msg = "unsupported platform/architecture"}
	}

	base, base_err := pythons_base_dir(allocator)
	if base_err != nil { return base_err }

	version_dir := strings.concatenate({base, "/", release.version}, allocator)
	bin_path := python_version_bin(base, release.version, allocator)

	// Already installed?
	if os.is_file(bin_path) {
		fmt.printfln("  Python %s already installed at %s", release.version, bin_path)
		return nil
	}

	// Create directory tree
	mkdir_err := os.make_directory_all(version_dir)
	if mkdir_err != nil && mkdir_err != .Exist {
		return Platform_Error_Data{
			msg = fmt.aprintf("cannot create '%s': %v", version_dir, mkdir_err, allocator = allocator),
		}
	}

	// Build download URL
	url := fmt.aprintf(
		"https://github.com/indygreg/python-build-standalone/releases/download/%s/cpython-%s+%s-%s-install_only.tar.gz",
		release.tag, release.version, release.tag, triple,
		allocator = allocator)

	// Temp file for tarball
	tmp_dir, tmp_err := os.temp_directory(allocator)
	if tmp_err != nil { tmp_dir = "/tmp" }
	tarball := fmt.aprintf("%s/mimir-python-%s.tar.gz", tmp_dir, release.version, allocator = allocator)

	fmt.printfln("  downloading Python %s...", release.version)
	fmt.printfln("  %s", url)

	// Download with curl (terminal I/O for progress bar)
	curl_proc, curl_start_err := os.process_start({
		command = {"curl", "-fSL", "--progress-bar", "-o", tarball, url},
		stdin  = os.stdin,
		stdout = os.stdout,
		stderr = os.stderr,
	})
	if curl_start_err != nil {
		return Platform_Error_Data{
			msg = fmt.aprintf("failed to start curl: %v", curl_start_err, allocator = allocator),
		}
	}
	curl_state, curl_wait_err := os.process_wait(curl_proc)
	if curl_wait_err != nil {
		return Platform_Error_Data{
			msg = fmt.aprintf("curl error: %v", curl_wait_err, allocator = allocator),
		}
	}
	if curl_state.exit_code != 0 {
		return Platform_Error_Data{
			msg = fmt.aprintf("download failed (curl exit %d); check the URL or network",
				curl_state.exit_code, allocator = allocator),
		}
	}

	// Verify SHA256 checksum
	tarball_filename := fmt.aprintf("cpython-%s+%s-%s-install_only.tar.gz",
		release.version, release.tag, triple, allocator = allocator)
	verify_err := verify_tarball_sha256(tarball, tarball_filename, release.tag, allocator)
	if verify_err != nil {
		os.remove(tarball)
		return verify_err
	}

	// Extract tarball
	fmt.printfln("  extracting to %s...", version_dir)

	tar_state, _, tar_stderr, tar_exec_err := os.process_exec({
		command = {"tar", "xf", tarball, "-C", version_dir},
	}, allocator)
	if tar_exec_err != nil {
		return Platform_Error_Data{
			msg = fmt.aprintf("failed to run tar: %v", tar_exec_err, allocator = allocator),
		}
	}
	if tar_state.exit_code != 0 {
		return Platform_Error_Data{
			msg = fmt.aprintf("extraction failed: %s", string(tar_stderr), allocator = allocator),
		}
	}

	// Clean up tarball (best effort)
	os.remove(tarball)

	// Verify binary exists
	if !os.is_file(bin_path) {
		return Platform_Error_Data{
			msg = fmt.aprintf("installed but binary not found at '%s'", bin_path, allocator = allocator),
		}
	}

	fmt.printfln("  installed Python %s → %s", release.version, bin_path)
	return nil
}

// ============================================================
// Tier 2: List / Remove / Version Selection
// ============================================================

list_installed_pythons :: proc(allocator: mem.Allocator) -> ([]Python_Version, Platform_Error) {
	base, base_err := pythons_base_dir(allocator)
	if base_err != nil { return nil, base_err }

	if !os.is_directory(base) {
		return nil, nil
	}

	entries, read_err := os.read_all_directory_by_path(base, allocator)
	if read_err != nil {
		return nil, Platform_Error_Data{
			msg = fmt.aprintf("cannot read '%s': %v", base, read_err, allocator = allocator),
		}
	}

	versions := make([dynamic]Python_Version, 0, len(entries), allocator)
	for entry in entries {
		if entry.type != .Directory { continue }
		bin_path := python_version_bin(base, entry.name, allocator)
		if os.is_file(bin_path) {
			append(&versions, Python_Version{
				version = entry.name,
				path    = bin_path,
			})
		}
	}

	return versions[:], nil
}

list_available_pythons :: proc() -> []Python_Release {
	return KNOWN_RELEASES[:]
}

remove_python :: proc(version: string, allocator: mem.Allocator) -> Platform_Error {
	base, base_err := pythons_base_dir(allocator)
	if base_err != nil { return base_err }

	// Find exact or prefix match among installed
	installed, list_err := list_installed_pythons(allocator)
	if list_err != nil { return list_err }

	target := ""
	for v in installed {
		if v.version == version {
			target = v.version
			break
		}
		if len(v.version) > len(version) &&
		   strings.has_prefix(v.version, version) &&
		   v.version[len(version)] == '.' {
			target = v.version
			break
		}
	}

	if target == "" {
		return Platform_Error_Data{
			msg = fmt.aprintf("Python %s is not installed", version, allocator = allocator),
		}
	}

	version_dir := strings.concatenate({base, "/", target}, allocator)

	// Remove directory tree
	rm_state, _, rm_stderr, rm_err := os.process_exec({
		command = {"rm", "-rf", version_dir},
	}, allocator)
	if rm_err != nil {
		return Platform_Error_Data{
			msg = fmt.aprintf("failed to remove '%s': %v", version_dir, rm_err, allocator = allocator),
		}
	}
	if rm_state.exit_code != 0 {
		return Platform_Error_Data{
			msg = fmt.aprintf("removal failed: %s", string(rm_stderr), allocator = allocator),
		}
	}

	fmt.printfln("  removed Python %s", target)
	return nil
}

// Find the best managed Python matching a version constraint.
// Returns full path to the python3 binary.
// If constraint is empty, returns the highest installed version.
find_managed_python :: proc(constraint: string, allocator: mem.Allocator) -> (path: string, ok: bool) {
	installed, err := list_installed_pythons(allocator)
	if err != nil || len(installed) == 0 {
		return "", false
	}

	// No constraint: return highest installed version
	if constraint == "" {
		best := 0
		for i := 1; i < len(installed); i += 1 {
			if version_greater(installed[i].version, installed[best].version) {
				best = i
			}
		}
		return installed[best].path, true
	}

	// Exact match
	for v in installed {
		if v.version == constraint {
			return v.path, true
		}
	}

	// Prefix match: find highest matching version
	best_path := ""
	best_ver := ""
	for v in installed {
		if strings.has_prefix(v.version, constraint) {
			if len(v.version) == len(constraint) ||
			   (len(v.version) > len(constraint) && v.version[len(constraint)] == '.') {
				if best_ver == "" || version_greater(v.version, best_ver) {
					best_path = v.path
					best_ver = v.version
				}
			}
		}
	}

	if best_path != "" {
		return best_path, true
	}
	return "", false
}

// Compare version strings: "3.12.7" > "3.12.4" > "3.11.10".
// Zero-allocation — parses numbers directly from the string.
// Verify downloaded tarball SHA256 against python-build-standalone SHA256SUMS.
@(private = "file")
verify_tarball_sha256 :: proc(tarball_path: string, tarball_filename: string, tag: string, allocator: mem.Allocator) -> Platform_Error {
	fmt.println("  verifying SHA256 checksum...")

	// Compute SHA256 of downloaded tarball
	sha_state, sha_stdout, _, sha_err := os.process_exec({
		command = {"shasum", "-a", "256", tarball_path},
	}, allocator)
	if sha_err != nil || sha_state.exit_code != 0 {
		fmt.eprintln("  WARNING: could not compute SHA256 — install is UNVERIFIED")
		fmt.eprintln("  Install 'shasum' or use --no-verify to suppress this warning")
		return nil
	}
	actual_hash := ""
	sha_output := string(sha_stdout)
	space_idx := strings.index_byte(sha_output, ' ')
	if space_idx > 0 {
		actual_hash = sha_output[:space_idx]
	}
	if len(actual_hash) != 64 {
		fmt.eprintln("  warning: unexpected shasum output — skipping verification")
		return nil
	}

	// Download SHA256SUMS from the release
	sums_url := fmt.aprintf(
		"https://github.com/indygreg/python-build-standalone/releases/download/%s/SHA256SUMS",
		tag, allocator = allocator)
	sums_state, sums_stdout, _, sums_err := os.process_exec({
		command = {"curl", "-fsSL", sums_url},
	}, allocator)
	if sums_err != nil || sums_state.exit_code != 0 {
		fmt.eprintln("  WARNING: could not download SHA256SUMS — install is UNVERIFIED")
		fmt.eprintln("  Check network connectivity or verify the tarball manually")
		return nil
	}

	// Parse SHA256SUMS: each line is "<hash>  <filename>"
	expected_hash := ""
	sums_content := string(sums_stdout)
	for line in strings.split_lines(sums_content, context.temp_allocator) {
		trimmed := strings.trim_space(line)
		if len(trimmed) < 66 { continue }  // 64 hash + 2 spaces + filename
		if strings.has_suffix(trimmed, tarball_filename) {
			expected_hash = trimmed[:64]
			break
		}
	}

	if expected_hash == "" {
		fmt.eprintln("  warning: tarball not found in SHA256SUMS — skipping verification")
		return nil
	}

	if actual_hash != expected_hash {
		return Platform_Error_Data{
			msg = fmt.aprintf("SHA256 mismatch!\n  expected: %s\n  actual:   %s\n  This may indicate a corrupted or tampered download.",
				expected_hash, actual_hash, allocator = allocator),
		}
	}

	fmt.println("  checksum verified OK")
	return nil
}

@(private = "file")
version_greater :: proc(a, b: string) -> bool {
	ai, bi := 0, 0
	for {
		an, bn := 0, 0
		for ai < len(a) && a[ai] >= '0' && a[ai] <= '9' {
			an = an * 10 + int(a[ai] - '0')
			ai += 1
		}
		for bi < len(b) && b[bi] >= '0' && b[bi] <= '9' {
			bn = bn * 10 + int(b[bi] - '0')
			bi += 1
		}
		if an != bn { return an > bn }
		if ai < len(a) && a[ai] == '.' { ai += 1 }
		if bi < len(b) && b[bi] == '.' { bi += 1 }
		if ai >= len(a) && bi >= len(b) { return false }
		if ai >= len(a) { return false }
		if bi >= len(b) { return true }
	}
}
