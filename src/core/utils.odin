package core

import "core:os"
import "core:strings"

IGNORE_DIRS :: [?]string{
	".git",
	"__pycache__",
	".venv",
	"venv",
	"node_modules",
	".tox",
	".mypy_cache",
	".pytest_cache",
	".eggs",
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
	if err != nil do return
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
	for ignore in IGNORE_DIRS {
		if name == ignore do return true
	}
	return false
}
