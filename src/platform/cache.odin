package platform

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:strings"

// Global package cache manager.
// Phase 8 layout: ~/.mimir/cache/packages/<name>/
// Phase 9 layout: ~/.mimir/cache/packages/<name>/<version>/
// Phase L4 layout: ~/.mimir/cache/cas/<prefix>/<hash>/  (content-addressed)

Cache :: struct {
	root:      string,   // ~/.mimir/cache
	packages:  string,   // ~/.mimir/cache/packages (legacy)
	cas:       string,   // ~/.mimir/cache/cas (content-addressed)
	allocator: mem.Allocator,
}

// Initialize the cache, creating directories if needed.
init_cache :: proc(allocator: mem.Allocator) -> (Cache, Platform_Error) {
	home, home_err := os.user_home_dir(allocator)
	if home_err != nil {
		return {}, Platform_Error_Data{msg = "cannot determine home directory"}
	}

	root := strings.concatenate({home, "/.mimir/cache"}, allocator)
	packages := strings.concatenate({root, "/packages"}, allocator)
	cas := strings.concatenate({root, "/cas"}, allocator)

	// Create directory tree
	mkdir_err := os.make_directory_all(packages)
	if mkdir_err != nil && mkdir_err != .Exist {
		return {}, Platform_Error_Data{msg = fmt.tprintf("cannot create cache directory '%s': %v", packages, mkdir_err)}
	}
	cas_err := os.make_directory_all(cas)
	if cas_err != nil && cas_err != .Exist {
		return {}, Platform_Error_Data{msg = fmt.tprintf("cannot create CAS directory '%s': %v", cas, cas_err)}
	}

	return Cache{
		root      = root,
		packages  = packages,
		cas       = cas,
		allocator = allocator,
	}, nil
}

// Check if a package is cached. Returns the path and whether it was found.
find_package :: proc(cache: ^Cache, name: string) -> (path: string, found: bool) {
	dir := package_dir(cache, name)
	if os.is_directory(dir) {
		return dir, true
	}
	return "", false
}

// Return the cache directory path for a package (unversioned — Phase 8 compat).
package_dir :: proc(cache: ^Cache, name: string) -> string {
	safe := sanitize_path_component(name)
	return strings.concatenate({cache.packages, "/", safe}, cache.allocator)
}

// Check if a versioned package is cached.
find_package_version :: proc(cache: ^Cache, name, version: string) -> (path: string, found: bool) {
	dir := package_version_dir(cache, name, version)
	if os.is_directory(dir) {
		return dir, true
	}
	return "", false
}

// Return the cache directory path for a versioned package.
package_version_dir :: proc(cache: ^Cache, name, version: string) -> string {
	safe_name := sanitize_path_component(name)
	safe_ver := sanitize_path_component(version)
	return strings.concatenate({cache.packages, "/", safe_name, "/", safe_ver}, cache.allocator)
}

// ==================== Content-Addressed Storage ====================

// Compute the CAS hash for a package name + version.
// Returns a 16-char hex string (FNV-64a of "name==version").
cas_hash :: proc(name, version: string, allocator: mem.Allocator) -> string {
	key := strings.concatenate({name, "==", version}, allocator)
	h := hash.fnv64a(transmute([]u8)key)
	return fmt.aprintf("%016x", h, allocator = allocator)
}

// Return the CAS directory path: ~/.mimir/cache/cas/<prefix>/<hash>/
cas_dir :: proc(cache: ^Cache, cas_key: string) -> string {
	prefix := cas_key[:4] if len(cas_key) >= 4 else cas_key
	return strings.concatenate({cache.cas, "/", prefix, "/", cas_key}, cache.allocator)
}

// Check if a package is in the CAS cache. Returns path and whether found.
find_cas_package :: proc(cache: ^Cache, name, version: string) -> (path: string, cas_key: string, found: bool) {
	key := cas_hash(name, version, cache.allocator)
	dir := cas_dir(cache, key)
	if os.is_directory(dir) {
		return dir, key, true
	}
	return "", key, false
}

// Return the CAS directory path for a name + version (creating parent if needed).
cas_target_dir :: proc(cache: ^Cache, name, version: string) -> (path: string, cas_key: string) {
	key := cas_hash(name, version, cache.allocator)
	dir := cas_dir(cache, key)
	// Ensure prefix dir exists
	prefix_dir := strings.concatenate({cache.cas, "/", key[:4] if len(key) >= 4 else key}, cache.allocator)
	os.make_directory_all(prefix_dir)
	return dir, key
}

// ==================== Content Hash Integrity ====================

// Write a .mimir-hash marker file alongside installed package content.
write_hash_marker :: proc(dir: string, content_hash: string, allocator: mem.Allocator) -> Platform_Error {
	if len(content_hash) == 0 { return nil }
	marker_path := strings.concatenate({dir, "/.mimir-hash"}, allocator)
	write_err := os.write_entire_file(marker_path, transmute([]u8)content_hash)
	if write_err != nil {
		return Platform_Error_Data{msg = fmt.tprintf("cannot write hash marker: %v", write_err)}
	}
	return nil
}

// Verify a cached package's .mimir-hash against expected content hash.
// Returns: verified (hash matches), found (marker exists).
verify_hash_marker :: proc(dir: string, expected_hash: string, allocator: mem.Allocator) -> (verified: bool, found: bool) {
	if len(expected_hash) == 0 { return false, false }
	marker_path := strings.concatenate({dir, "/.mimir-hash"}, allocator)
	data, read_err := os.read_entire_file(marker_path, allocator)
	if read_err != nil {
		return false, false
	}
	stored := strings.trim_space(string(data))
	return stored == expected_hash, true
}

// Find a versioned package with optional integrity verification.
// Returns path, found, and whether integrity was verified.
find_verified_package :: proc(
	cache: ^Cache, name, version, expected_hash: string,
) -> (path: string, found: bool, verified: bool) {
	dir := package_version_dir(cache, name, version)
	if !os.is_directory(dir) {
		return "", false, false
	}
	if len(expected_hash) == 0 {
		return dir, true, false // found but unverified (no hash to check)
	}
	v, marker_found := verify_hash_marker(dir, expected_hash, cache.allocator)
	if !marker_found {
		return dir, true, false // found but no marker (legacy)
	}
	return dir, true, v
}

// ==================== Cache GC ====================

Cache_Entry :: struct {
	name:    string,
	version: string,
	path:    string,
	is_cas:  bool,    // true = legacy CAS layout, false = versioned layout
}

// List all cached packages. Scans both versioned and CAS directories.
list_cache :: proc(cache: ^Cache, allocator: mem.Allocator) -> [dynamic]Cache_Entry {
	entries := make([dynamic]Cache_Entry, 0, 32, allocator)

	// Scan versioned layout: packages/<name>/<version>/
	pkg_dirs, pkg_err := os.read_all_directory_by_path(cache.packages, allocator)
	if pkg_err == nil {
		for pkg_dir in pkg_dirs {
			if pkg_dir.type != .Directory { continue }
			pkg_name := pkg_dir.name
			pkg_path := strings.concatenate({cache.packages, "/", pkg_name}, allocator)
			ver_dirs, ver_err := os.read_all_directory_by_path(pkg_path, allocator)
			if ver_err == nil {
				has_versions := false
				for ver_dir in ver_dirs {
					if ver_dir.type != .Directory { continue }
					has_versions = true
					append(&entries, Cache_Entry{
						name    = strings.clone(pkg_name, allocator),
						version = strings.clone(ver_dir.name, allocator),
						path    = strings.concatenate({pkg_path, "/", ver_dir.name}, allocator),
						is_cas  = false,
					})
				}
				// Unversioned package dir (Phase 8 legacy — no version subdirs)
				if !has_versions {
					append(&entries, Cache_Entry{
						name    = strings.clone(pkg_name, allocator),
						version = "",
						path    = strings.clone(pkg_path, allocator),
						is_cas  = false,
					})
				}
			}
		}
	}

	// Scan CAS layout: cas/<prefix>/<hash>/
	cas_prefixes, cas_err := os.read_all_directory_by_path(cache.cas, allocator)
	if cas_err == nil {
		for prefix_dir in cas_prefixes {
			if prefix_dir.type != .Directory { continue }
			prefix_path := strings.concatenate({cache.cas, "/", prefix_dir.name}, allocator)
			hash_dirs, hash_err := os.read_all_directory_by_path(prefix_path, allocator)
			if hash_err == nil {
				for hash_dir in hash_dirs {
					if hash_dir.type != .Directory { continue }
					append(&entries, Cache_Entry{
						name    = strings.clone(hash_dir.name, allocator),
						version = "",
						path    = strings.concatenate({prefix_path, "/", hash_dir.name}, allocator),
						is_cas  = true,
					})
				}
			}
		}
	}

	return entries
}

// Remove cached packages not in the given lockfile.
// Returns number of entries removed.
gc_cache :: proc(cache: ^Cache, lf: ^Lockfile, allocator: mem.Allocator) -> (removed: int, err: Platform_Error) {
	entries := list_cache(cache, allocator)

	// Build set of locked packages: "name==version"
	locked := make(map[string]bool, len(lf.packages), allocator)
	for pkg in lf.packages {
		key := strings.concatenate({pkg.name, "==", pkg.version}, allocator)
		locked[key] = true
	}

	removed = 0
	for entry in entries {
		keep := false
		if entry.is_cas {
			// CAS entries: keep if any locked package maps to this hash
			for pkg in lf.packages {
				if len(pkg.hash) > 0 {
					cdir := cas_dir(cache, pkg.hash)
					if cdir == entry.path {
						keep = true
						break
					}
				}
			}
		} else if len(entry.version) > 0 {
			key := strings.concatenate({entry.name, "==", entry.version}, allocator)
			keep = key in locked
		}
		// Unversioned entries (Phase 8 legacy) are never matched — they get cleaned

		if !keep {
			rm_err := os.remove_all(entry.path)
			if rm_err != nil {
				return removed, Platform_Error_Data{msg = fmt.tprintf("failed to remove '%s': %v", entry.path, rm_err)}
			}
			removed += 1
		}
	}

	// Clean up empty parent directories in packages/
	pkg_dirs, _ := os.read_all_directory_by_path(cache.packages, allocator)
	for pkg_dir in pkg_dirs {
		if pkg_dir.type != .Directory { continue }
		pkg_path := strings.concatenate({cache.packages, "/", pkg_dir.name}, allocator)
		children, _ := os.read_all_directory_by_path(pkg_path, allocator)
		if len(children) == 0 {
			os.remove_all(pkg_path)
		}
	}

	// Clean up empty prefix directories in cas/
	cas_prefixes, _ := os.read_all_directory_by_path(cache.cas, allocator)
	for prefix_dir in cas_prefixes {
		if prefix_dir.type != .Directory { continue }
		prefix_path := strings.concatenate({cache.cas, "/", prefix_dir.name}, allocator)
		children, _ := os.read_all_directory_by_path(prefix_path, allocator)
		if len(children) == 0 {
			os.remove_all(prefix_path)
		}
	}

	return removed, nil
}

// Remove all cached packages. Returns number of entries removed.
clean_cache :: proc(cache: ^Cache, allocator: mem.Allocator) -> (removed: int, err: Platform_Error) {
	entries := list_cache(cache, allocator)
	removed = 0
	for entry in entries {
		rm_err := os.remove_all(entry.path)
		if rm_err != nil {
			return removed, Platform_Error_Data{msg = fmt.tprintf("failed to remove '%s': %v", entry.path, rm_err)}
		}
		removed += 1
	}
	return removed, nil
}

// ==================== Helpers ====================

// Sanitize a path component: strip directory separators and ".." to prevent traversal
sanitize_path_component :: proc(s: string) -> string {
	if strings.contains(s, "..") || strings.contains(s, "/") || strings.contains(s, "\\") {
		// Strip dangerous characters, keep only safe chars
		buf := make([dynamic]u8, 0, len(s))
		for c in s {
			if c == '/' || c == '\\' { continue }
			append(&buf, u8(c))
		}
		result := string(buf[:])
		// Strip leading/trailing dots
		result = strings.trim(result, ".")
		if len(result) == 0 { return "_invalid_" }
		return result
	}
	return s
}
