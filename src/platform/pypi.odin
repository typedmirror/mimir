package platform

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:slice"
import "core:strconv"

// ==================== Native PyPI Package Resolver ====================
//
// Queries PyPI JSON API directly via curl, downloads wheels, resolves deps.
// Eliminates pip dependency for mimir add/install/lock.

// ==================== Version Parsing ====================

Version :: struct {
	major: int,
	minor: int,
	patch: int,
}

Constraint_Op :: enum {
	Eq,      // ==
	Gte,     // >=
	Gt,      // >
	Lte,     // <=
	Lt,      // <
	Neq,     // !=
	Compat,  // ~=
}

Constraint :: struct {
	op:      Constraint_Op,
	version: Version,
}

parse_version :: proc(s: string) -> (Version, bool) {
	v: Version
	parts := strings.split(s, ".", context.temp_allocator)
	if len(parts) < 1 { return v, false }
	major, major_ok := strconv.parse_int(parts[0])
	if !major_ok { return v, false }
	v.major = major
	if len(parts) >= 2 {
		minor, minor_ok := strconv.parse_int(parts[1])
		if minor_ok { v.minor = minor }
	}
	if len(parts) >= 3 {
		// Handle "3.1.3.post1" — take only numeric prefix
		patch_str := parts[2]
		for i := 0; i < len(patch_str); i += 1 {
			if patch_str[i] < '0' || patch_str[i] > '9' {
				patch_str = patch_str[:i]
				break
			}
		}
		if len(patch_str) > 0 {
			patch, patch_ok := strconv.parse_int(patch_str)
			if patch_ok { v.patch = patch }
		}
	}
	return v, true
}

version_compare :: proc(a, b: Version) -> int {
	if a.major != b.major { return a.major - b.major }
	if a.minor != b.minor { return a.minor - b.minor }
	return a.patch - b.patch
}

parse_constraint :: proc(s: string) -> ([]Constraint, bool) {
	trimmed := strings.trim_space(s)
	if len(trimmed) == 0 { return nil, true } // no constraint = any version

	parts := strings.split(trimmed, ",", context.temp_allocator)
	result := make([dynamic]Constraint, 0, len(parts))
	for part in parts {
		p := strings.trim_space(part)
		if len(p) == 0 { continue }

		c: Constraint
		ver_start := 0

		if strings.has_prefix(p, ">=") {
			c.op = .Gte; ver_start = 2
		} else if strings.has_prefix(p, "<=") {
			c.op = .Lte; ver_start = 2
		} else if strings.has_prefix(p, "!=") {
			c.op = .Neq; ver_start = 2
		} else if strings.has_prefix(p, "~=") {
			c.op = .Compat; ver_start = 2
		} else if strings.has_prefix(p, "==") {
			c.op = .Eq; ver_start = 2
		} else if strings.has_prefix(p, ">") {
			c.op = .Gt; ver_start = 1
		} else if strings.has_prefix(p, "<") {
			c.op = .Lt; ver_start = 1
		} else {
			// No operator — treat as exact match
			c.op = .Eq; ver_start = 0
		}

		ver_str := strings.trim_space(p[ver_start:])
		// Strip wildcard suffix: "3.*" → "3"
		if strings.has_suffix(ver_str, ".*") {
			ver_str = ver_str[:len(ver_str)-2]
		}
		ver, ok := parse_version(ver_str)
		if !ok { continue }
		c.version = ver
		append(&result, c)
	}
	return result[:], true
}

version_satisfies :: proc(v: Version, constraints: []Constraint) -> bool {
	for c in constraints {
		cmp := version_compare(v, c.version)
		switch c.op {
		case .Eq:     if cmp != 0 { return false }
		case .Gte:    if cmp < 0  { return false }
		case .Gt:     if cmp <= 0 { return false }
		case .Lte:    if cmp > 0  { return false }
		case .Lt:     if cmp >= 0 { return false }
		case .Neq:    if cmp == 0 { return false }
		case .Compat:
			// ~=3.1 means >=3.1, <4.0
			if v.major != c.version.major { return false }
			if version_compare(v, c.version) < 0 { return false }
		}
	}
	return true
}

// Check if a version string satisfies a constraint string.
_version_str_satisfies :: proc(version_str: string, constraint_str: string) -> bool {
	ver, ver_ok := parse_version(version_str)
	if !ver_ok { return true } // can't parse → don't flag conflict
	constraints, con_ok := parse_constraint(constraint_str)
	if !con_ok { return true }
	return version_satisfies(ver, constraints)
}

// ==================== PyPI JSON API ====================

PyPI_Package :: struct {
	name:          string,
	version:       string,
	requires_dist: [dynamic]string,
	download_url:  string,
	sha256:        string,
	filename:      string,
}

// Query PyPI for package metadata. Returns the best matching version.
query_pypi :: proc(
	name: string,
	version_constraint: string,
	allocator: mem.Allocator,
) -> (pkg: PyPI_Package, err: Platform_Error) {
	// Validate package name before URL construction (prevent path traversal)
	for i := 0; i < len(name); i += 1 {
		c := name[i]
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
		     c == '-' || c == '_' || c == '.') {
			return {}, Platform_Error_Data{msg = fmt.tprintf("invalid package name '%s': contains illegal character '%c'", name, rune(c))}
		}
	}

	// Fetch package JSON from PyPI
	url := fmt.aprintf("https://pypi.org/pypi/%s/json", name, allocator = allocator)

	tmp_dir, tmp_err := os.temp_directory(allocator)
	if tmp_err != nil { tmp_dir = "/tmp" }
	tmp_file := fmt.aprintf("%s/mimir_pypi_%s_%d.json", tmp_dir, name, os.get_pid(), allocator = allocator)
	defer {
		if os.exists(tmp_file) { os.remove(tmp_file) }
	}

	// curl -fsSL -o tmp_file url
	_, _, curl_stderr, curl_err := os.process_exec({
		command = {"curl", "-fsSL", "-o", tmp_file, url},
	}, allocator)
	if curl_err != nil {
		return {}, Platform_Error_Data{msg = fmt.tprintf("failed to query PyPI for '%s': %v", name, curl_err)}
	}
	if curl_stderr != nil && len(curl_stderr) > 0 {
		stderr_str := string(curl_stderr)
		if strings.contains(stderr_str, "404") || strings.contains(stderr_str, "Not Found") {
			return {}, Platform_Error_Data{msg = fmt.tprintf("package '%s' not found on PyPI", name)}
		}
	}

	data, read_err := os.read_entire_file(tmp_file, allocator)
	if read_err != nil {
		return {}, Platform_Error_Data{msg = fmt.tprintf("cannot read PyPI response for '%s': %v", name, read_err)}
	}

	parsed, json_err := json.parse(data, .JSON, true, allocator)
	if json_err != nil {
		return {}, Platform_Error_Data{msg = fmt.tprintf("cannot parse PyPI JSON for '%s': %v", name, json_err)}
	}

	root, root_ok := parsed.(json.Object)
	if !root_ok {
		return {}, Platform_Error_Data{msg = fmt.tprintf("PyPI response for '%s' is not a JSON object", name)}
	}

	// Parse constraint
	constraints, _ := parse_constraint(version_constraint)

	// Find best version from releases
	releases_val, has_releases := root["releases"]
	if !has_releases {
		return {}, Platform_Error_Data{msg = fmt.tprintf("PyPI response for '%s' has no releases", name)}
	}
	releases, releases_ok := releases_val.(json.Object)
	if !releases_ok {
		return {}, Platform_Error_Data{msg = fmt.tprintf("PyPI releases for '%s' is not an object", name)}
	}

	// Collect valid versions
	best_version := Version{}
	best_version_str := ""
	found_any := false

	for ver_str in releases {
		ver, ver_ok := parse_version(ver_str)
		if !ver_ok { continue }
		if len(constraints) > 0 && !version_satisfies(ver, constraints) { continue }
		if !found_any || version_compare(ver, best_version) > 0 {
			best_version = ver
			best_version_str = ver_str
			found_any = true
		}
	}

	if !found_any {
		return {}, Platform_Error_Data{msg = fmt.tprintf("no version of '%s' satisfies constraint '%s'", name, version_constraint)}
	}

	// Get wheel URL from the best version's release files
	release_files_val := releases[best_version_str]
	release_files, rf_ok := release_files_val.(json.Array)
	if !rf_ok || len(release_files) == 0 {
		return {}, Platform_Error_Data{msg = fmt.tprintf("no files for '%s' version %s", name, best_version_str)}
	}

	// Prefer py3-none-any wheel, then any wheel
	wheel_url := ""
	wheel_sha256 := ""
	wheel_filename := ""

	for rf in release_files {
		rf_obj, rf_obj_ok := rf.(json.Object)
		if !rf_obj_ok { continue }

		fn_val, has_fn := rf_obj["filename"]
		if !has_fn { continue }
		fn_str, fn_ok := fn_val.(json.String)
		if !fn_ok { continue }

		if !strings.has_suffix(fn_str, ".whl") { continue }

		url_val, has_url := rf_obj["url"]
		if !has_url { continue }
		url_str, url_ok := url_val.(json.String)
		if !url_ok { continue }

		// Extract SHA256
		sha := ""
		if dig_val, has_dig := rf_obj["digests"]; has_dig {
			if dig_obj, dig_ok := dig_val.(json.Object); dig_ok {
				if sha_val, has_sha := dig_obj["sha256"]; has_sha {
					if sha_str, sha_ok := sha_val.(json.String); sha_ok {
						sha = sha_str
					}
				}
			}
		}

		// Prefer py3-none-any (pure Python, universal)
		if strings.contains(fn_str, "py3-none-any") {
			wheel_url = url_str
			wheel_sha256 = sha
			wheel_filename = fn_str
			break // best possible match
		}

		// Accept any wheel as fallback
		if len(wheel_url) == 0 {
			wheel_url = url_str
			wheel_sha256 = sha
			wheel_filename = fn_str
		}
	}

	if len(wheel_url) == 0 {
		return {}, Platform_Error_Data{msg = fmt.tprintf("no wheel found for '%s' version %s", name, best_version_str)}
	}

	// Extract requires_dist from info
	pkg.name = strings.to_lower(name, allocator)
	pkg.version = strings.clone(best_version_str, allocator)
	pkg.download_url = strings.clone(wheel_url, allocator)
	pkg.sha256 = strings.clone(wheel_sha256, allocator)
	pkg.filename = strings.clone(wheel_filename, allocator)
	pkg.requires_dist = make([dynamic]string, 0, 8, allocator)

	if info_val, has_info := root["info"]; has_info {
		if info_obj, info_ok := info_val.(json.Object); info_ok {
			if rd_val, has_rd := info_obj["requires_dist"]; has_rd {
				if rd_arr, rd_ok := rd_val.(json.Array); rd_ok {
					for rd in rd_arr {
						if rd_str, s_ok := rd.(json.String); s_ok {
							// Skip extras-only deps: "foo ; extra == 'bar'"
							if strings.contains(rd_str, "extra ==") || strings.contains(rd_str, "extra==") {
								continue
							}
							// Strip environment markers for now: "foo>=1.0 ; python_version >= '3.8'" → "foo>=1.0"
							clean := rd_str
							semi_idx := strings.index(rd_str, ";")
							if semi_idx >= 0 {
								clean = strings.trim_space(rd_str[:semi_idx])
							}
							if len(clean) > 0 {
								append(&pkg.requires_dist, strings.clone(clean, allocator))
							}
						}
					}
				}
			}
		}
	}

	return pkg, nil
}

// ==================== Native Dependency Resolution ====================

// Resolve dependencies natively via PyPI JSON API.
// Greedy algorithm: pick latest satisfying version, no backtracking.
resolve_native :: proc(deps: []Dep_Spec, allocator: mem.Allocator) -> ([]Locked_Package, Platform_Error) {
	if len(deps) == 0 {
		return make([]Locked_Package, 0, allocator), nil
	}

	resolved := make(map[string]Locked_Package, len(deps) * 3, allocator)
	queue := make([dynamic]Dep_Spec, 0, len(deps) * 2, allocator)

	// Seed queue with direct deps
	for dep in deps {
		append(&queue, dep)
	}

	qi := 0
	for qi < len(queue) {
		dep := queue[qi]
		qi += 1

		pkg_name := strings.to_lower(dep.name, allocator)
		if existing, already := resolved[pkg_name]; already {
			// Check for version conflict: if the new dep has a constraint,
			// verify the already-resolved version satisfies it
			if len(dep.constraint) > 0 && !_version_str_satisfies(existing.version, dep.constraint) {
				return nil, Platform_Error_Data{msg = fmt.tprintf(
					"version conflict: '%s' resolved to %s but '%s' requires %s",
					pkg_name, existing.version, dep.name, dep.constraint)}
			}
			continue
		}

		// Query PyPI
		pkg, query_err := query_pypi(dep.name, dep.constraint, allocator)
		if query_err != nil {
			return nil, query_err
		}

		// Record resolved package
		resolved[pkg_name] = Locked_Package{
			name         = pkg.name,
			version      = pkg.version,
			content_hash = fmt.aprintf("sha256:%s", pkg.sha256, allocator = allocator) if len(pkg.sha256) > 0 else "",
		}

		// Enqueue transitive deps
		for rd in pkg.requires_dist {
			td := parse_dep_spec(rd, allocator)
			td_lower := strings.to_lower(td.name, allocator)
			if td_lower not_in resolved {
				append(&queue, td)
			}
		}
	}

	// Convert map to sorted slice
	packages := make([dynamic]Locked_Package, 0, len(resolved), allocator)
	for _, pkg in resolved {
		append(&packages, pkg)
	}
	slice.sort_by(packages[:], proc(a, b: Locked_Package) -> bool {
		return a.name < b.name
	})

	result := make([]Locked_Package, len(packages), allocator)
	copy(result, packages[:])
	return result, nil
}

// ==================== Native Installer ====================

// Download and install a wheel directly from PyPI.
install_package_native :: proc(
	pkg: ^Locked_Package,
	cache: ^Cache,
	allocator: mem.Allocator,
) -> Platform_Error {
	// Query PyPI for the download URL
	pypi_pkg, query_err := query_pypi(pkg.name, fmt.tprintf("==%s", pkg.version), allocator)
	if query_err != nil {
		return query_err
	}

	// Target directory: cache/packages/<name>/<version>/
	target_dir := fmt.aprintf("%s/%s/%s", cache.packages, pkg.name, pkg.version, allocator = allocator)
	if os.is_directory(target_dir) {
		// Already installed — verify hash
		if len(pkg.content_hash) > 0 {
			verified, _ := verify_hash_marker(target_dir, pkg.content_hash, allocator)
			if verified {
				return nil // already installed and verified
			}
		} else {
			return nil // already installed, no hash to verify
		}
	}

	// Create temp dir for download
	tmp_dir := fmt.aprintf("%s.tmp", target_dir, allocator = allocator)
	if os.exists(tmp_dir) { os.remove_all(tmp_dir) }

	// Download wheel
	wheel_path := fmt.aprintf("%s/%s", tmp_dir, pypi_pkg.filename, allocator = allocator)
	os.make_directory(tmp_dir)

	_, _, _, curl_err := os.process_exec({
		command = {"curl", "-fsSL", "-o", wheel_path, pypi_pkg.download_url},
	}, allocator)
	if curl_err != nil {
		if os.exists(tmp_dir) { os.remove_all(tmp_dir) }
		return Platform_Error_Data{msg = fmt.tprintf("failed to download '%s': %v", pkg.name, curl_err)}
	}

	// Extract wheel (zip) into target
	extract_dir := fmt.aprintf("%s/extracted", tmp_dir, allocator = allocator)
	os.make_directory(extract_dir)

	_, _, unzip_stderr, unzip_err := os.process_exec({
		command = {"unzip", "-q", "-o", wheel_path, "-d", extract_dir},
	}, allocator)
	if unzip_err != nil {
		if os.exists(tmp_dir) { os.remove_all(tmp_dir) }
		stderr_msg := string(unzip_stderr) if unzip_stderr != nil else ""
		return Platform_Error_Data{msg = fmt.tprintf("failed to extract wheel for '%s': %v %s", pkg.name, unzip_err, stderr_msg)}
	}

	// Move extracted content to target
	if os.exists(target_dir) { os.remove_all(target_dir) }
	rename_err := os.rename(extract_dir, target_dir)
	if rename_err != nil {
		if os.exists(tmp_dir) { os.remove_all(tmp_dir) }
		return Platform_Error_Data{msg = fmt.tprintf("failed to install '%s': %v", pkg.name, rename_err)}
	}

	// Write hash marker
	if len(pkg.content_hash) > 0 {
		write_hash_marker(target_dir, pkg.content_hash, allocator)
	}

	// Clean up temp
	if os.exists(tmp_dir) { os.remove_all(tmp_dir) }

	return nil
}
