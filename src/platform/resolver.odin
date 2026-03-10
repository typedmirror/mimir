package platform

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"

// Pip-delegated dependency resolver.
// Uses `pip install --dry-run --report` to resolve all transitive deps.

// Resolve dependencies via pip --dry-run --report.
// Returns sorted list of locked packages (direct + transitive).
resolve :: proc(python: string, deps: []Dep_Spec, allocator: mem.Allocator) -> ([]Locked_Package, Platform_Error) {
	if len(deps) == 0 {
		result := make([]Locked_Package, 0, allocator)
		return result, nil
	}

	// Create temp file for report
	tmp_dir, tmp_err := os.temp_directory(allocator)
	if tmp_err != nil {
		tmp_dir = "/tmp"
	}
	report_path := strings.concatenate({tmp_dir, "/mimir_pip_report.json"}, allocator)
	defer {
		if os.exists(report_path) {
			os.remove(report_path)
		}
	}

	// Build pip command: python -m pip install --dry-run --report <file> <deps...>
	cmd := make([dynamic]string, 0, 8 + len(deps), allocator)
	append(&cmd, python)
	append(&cmd, "-m")
	append(&cmd, "pip")
	append(&cmd, "install")
	append(&cmd, "--dry-run")
	append(&cmd, "--report")
	append(&cmd, report_path)
	append(&cmd, "--quiet")
	for dep in deps {
		append(&cmd, dep.raw)
	}

	// Run pip
	state, _, stderr, exec_err := os.process_exec({
		command = cmd[:],
	}, allocator)
	if exec_err != nil {
		return nil, Platform_Error_Data{msg = fmt.tprintf("failed to run pip for resolution: %v", exec_err)}
	}
	if state.exit_code != 0 {
		msg := string(stderr) if len(stderr) > 0 else "unknown error"
		return nil, Platform_Error_Data{msg = fmt.tprintf("pip resolution failed: %s", strings.trim_space(msg))}
	}

	// Read report JSON
	report_data, read_err := os.read_entire_file(report_path, allocator)
	if read_err != nil {
		return nil, Platform_Error_Data{msg = fmt.tprintf("cannot read pip report: %v", read_err)}
	}

	// Parse JSON
	parsed, json_err := json.parse(report_data, .JSON, true, allocator)
	if json_err != nil {
		return nil, Platform_Error_Data{msg = fmt.tprintf("cannot parse pip report JSON: %v", json_err)}
	}

	// Extract install[].metadata.{name, version}
	packages := make([dynamic]Locked_Package, 0, len(deps) * 2, allocator)

	root_obj, root_ok := parsed.(json.Object)
	if !root_ok {
		return nil, Platform_Error_Data{msg = "pip report: expected JSON object"}
	}

	install_val, has_install := root_obj["install"]
	if !has_install {
		// No packages to install — could be all satisfied
		result := make([]Locked_Package, 0, allocator)
		return result, nil
	}

	install_arr, arr_ok := install_val.(json.Array)
	if !arr_ok {
		return nil, Platform_Error_Data{msg = "pip report: 'install' is not an array"}
	}

	for item in install_arr {
		item_obj, item_ok := item.(json.Object)
		if !item_ok { continue }

		meta_val, has_meta := item_obj["metadata"]
		if !has_meta { continue }

		meta_obj, meta_ok := meta_val.(json.Object)
		if !meta_ok { continue }

		name_val, has_name := meta_obj["name"]
		ver_val, has_ver := meta_obj["version"]
		if !has_name || !has_ver { continue }

		name_str, name_ok := name_val.(json.String)
		ver_str, ver_ok := ver_val.(json.String)
		if !name_ok || !ver_ok { continue }

		append(&packages, Locked_Package{
			name    = strings.to_lower(name_str, allocator),
			version = strings.clone(ver_str, allocator),
		})
	}

	// Sort by name
	slice.sort_by(packages[:], proc(a, b: Locked_Package) -> bool {
		return a.name < b.name
	})

	result := make([]Locked_Package, len(packages), allocator)
	copy(result, packages[:])
	return result, nil
}
