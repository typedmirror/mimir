package platform

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// Global package cache manager.
// Phase 8 layout: ~/.mimir/cache/packages/<name>/
// Phase 9 layout: ~/.mimir/cache/packages/<name>/<version>/

Cache :: struct {
	root:      string,   // ~/.mimir/cache
	packages:  string,   // ~/.mimir/cache/packages
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

	// Create directory tree
	mkdir_err := os.make_directory_all(packages)
	if mkdir_err != nil && mkdir_err != .Exist {
		return {}, Platform_Error_Data{msg = fmt.tprintf("cannot create cache directory '%s': %v", packages, mkdir_err)}
	}

	return Cache{
		root      = root,
		packages  = packages,
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
