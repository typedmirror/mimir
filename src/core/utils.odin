package core

import "core:fmt"
import "core:os"
import "core:strings"

IGNORE_DIRS :: [?]string{
	".git",
	".claude",
	"__pycache__",
	".venv",
	"venv",
	"node_modules",
	".tox",
	".mypy_cache",
	".pytest_cache",
	".eggs",
	".mimir",
	"build",
	"dist",
}

find_python_files :: proc(root: string, allocator := context.allocator) -> ([]string, os.Error) {
	// Single file
	if strings.has_suffix(root, ".py") {
		fi, err := os.stat(root, context.temp_allocator)
		if err != nil do return nil, err
		os.file_info_delete(fi, context.temp_allocator)
		result := make([]string, 1, allocator)
		result[0] = strings.clone(root, allocator)
		return result, nil
	}

	// Directory walk — verify root is readable before walking
	files: [dynamic]string
	files.allocator = allocator
	test_entries, dir_err := os.read_all_directory_by_path(root, context.temp_allocator)
	if dir_err != nil do return nil, dir_err
	os.file_info_slice_delete(test_entries, context.temp_allocator)
	_walk_dir(root, &files, allocator)
	return files[:], nil
}

MAX_WALK_DEPTH :: 64

@(private = "file")
_walk_dir :: proc(dir: string, files: ^[dynamic]string, allocator := context.allocator, depth: int = 0) {
	if depth >= MAX_WALK_DEPTH { return } // guard against symlink cycles
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("warning: could not read directory '%s': skipping", dir)
		return
	}
	defer os.file_info_slice_delete(entries, context.temp_allocator)

	for entry in entries {
		if entry.type == .Directory {
			if _is_ignored(entry.name) do continue
			_walk_dir(entry.fullpath, files, allocator, depth + 1)
		} else if strings.has_suffix(entry.name, ".py") {
			append(files, strings.clone(entry.fullpath, allocator))
		}
	}
}

@(private = "file")
_is_ignored :: proc(name: string) -> bool {
	// Hidden/dot-directories are NEVER descended into by any directory walk —
	// this is a general rule, not just the specific IGNORE_DIRS entries below
	// (S114 launch-blocker fix: .claude/worktrees/ held other agents' full
	// repo checkouts on disk and was not excluded, so any promoted or
	// directory-target walk that reached the repo root would recurse into
	// them). "." and ".." are never returned by directory listing, so this
	// is safe.
	if len(name) > 0 && name[0] == '.' { return true }
	for ignore in IGNORE_DIRS {
		if name == ignore do return true
	}
	return false
}

// Project root markers — presence of any of these indicates a project root directory.
PROJECT_MARKERS :: [?]string{
	".git",
	"mimir.toml",
	"pyproject.toml",
	"setup.py",
	"setup.cfg",
}

// Walk up from a file path to find the project root.
// Returns the project root directory, or "" if no markers found.
// Stops at filesystem root or after 20 levels.
find_project_root :: proc(start_path: string, allocator := context.allocator) -> string {
	// Get the directory containing the starting file
	dir := start_path
	if strings.has_suffix(start_path, ".py") || strings.has_suffix(start_path, ".pyi") {
		for i := len(dir) - 1; i >= 0; i -= 1 {
			if dir[i] == '/' { dir = dir[:i]; break }
			if i == 0 { dir = "." }
		}
	}

	// Walk up, checking for project markers at each level
	for level := 0; level < 20; level += 1 {
		if len(dir) == 0 || dir == "/" { break }

		for marker in PROJECT_MARKERS {
			marker_path := strings.concatenate({dir, "/", marker}, context.temp_allocator)
			if os.exists(marker_path) {
				return strings.clone(dir, allocator)
			}
		}

		// Go up one level
		found_slash := false
		for i := len(dir) - 1; i >= 0; i -= 1 {
			if dir[i] == '/' {
				dir = dir[:i]
				found_slash = true
				break
			}
		}
		if !found_slash { break }
	}

	return ""
}
