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
	return strings.concatenate({cache.packages, "/", name}, cache.allocator)
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
	return strings.concatenate({cache.packages, "/", name, "/", version}, cache.allocator)
}
