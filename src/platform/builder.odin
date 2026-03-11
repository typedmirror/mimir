package platform

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// Package building — wheel (.whl) and sdist (.tar.gz) from mimir.toml metadata.

Build_Config :: struct {
	name:            string,
	version:         string,
	description:     string,
	author:          string,
	author_email:    string,
	license_text:    string,
	readme_path:     string,
	requires_python: string,
	dependencies:    [dynamic]Dep_Spec,
	scripts:         [dynamic]Entry_Point,
	project_dir:     string,
}

Entry_Point :: struct {
	name: string,
	ref:  string,
}

Source_Files :: struct {
	root:     string,
	files:    [dynamic]string,
	packages: [dynamic]string,
}

// Read packaging metadata from mimir.toml.
read_build_config :: proc(config_path: string, allocator: mem.Allocator) -> (Build_Config, Platform_Error) {
	data, read_err := os.read_entire_file(config_path, allocator)
	if read_err != nil {
		return {}, Platform_Error_Data{msg = fmt.tprintf("cannot read '%s': %v", config_path, read_err)}
	}

	doc, parse_err := toml_parse(string(data), allocator)
	if parse_err != nil {
		return {}, parse_err
	}

	cfg := Build_Config{
		dependencies = make([dynamic]Dep_Spec, 0, 8, allocator),
		scripts      = make([dynamic]Entry_Point, 0, 4, allocator),
		project_dir  = parent_dir(config_path),
	}

	if v, ok := toml_get(&doc, "project", "name"); ok { cfg.name = v }
	if v, ok := toml_get(&doc, "project", "version"); ok { cfg.version = v }
	if v, ok := toml_get(&doc, "project", "description"); ok { cfg.description = v }
	if v, ok := toml_get(&doc, "project", "author"); ok { cfg.author = v }
	if v, ok := toml_get(&doc, "project", "author-email"); ok { cfg.author_email = v }
	if v, ok := toml_get(&doc, "project", "license"); ok { cfg.license_text = v }
	if v, ok := toml_get(&doc, "project", "readme"); ok { cfg.readme_path = v }
	if v, ok := toml_get(&doc, "project", "requires-python"); ok { cfg.requires_python = v }

	if deps_table, has_deps := doc.tables["dependencies"]; has_deps {
		for dep_name in deps_table.order {
			constraint := deps_table.entries[dep_name]
			raw: string
			if constraint == "" {
				raw = dep_name
			} else {
				raw = strings.concatenate({dep_name, constraint}, allocator)
			}
			append(&cfg.dependencies, Dep_Spec{
				name       = dep_name,
				constraint = constraint,
				raw        = raw,
			})
		}
	}

	if scripts_table, has_scripts := doc.tables["scripts"]; has_scripts {
		for script_name in scripts_table.order {
			ref := scripts_table.entries[script_name]
			append(&cfg.scripts, Entry_Point{
				name = script_name,
				ref  = ref,
			})
		}
	}

	return cfg, nil
}

// Validate that required fields are present for building.
validate_build_config :: proc(cfg: ^Build_Config) -> Platform_Error {
	if cfg.name == "" {
		return Platform_Error_Data{msg = "mimir.toml: [project] name is required for building"}
	}
	if cfg.version == "" {
		return Platform_Error_Data{msg = "mimir.toml: [project] version is required for building"}
	}
	return nil
}

// Normalize package name for wheel filename (PEP 427: replace - and . with _).
normalize_name :: proc(name: string, allocator: mem.Allocator) -> string {
	parts := make([dynamic]u8, 0, len(name), allocator)
	for c in transmute([]u8)name {
		if c == '-' || c == '.' {
			append(&parts, '_')
		} else {
			append(&parts, c)
		}
	}
	return string(parts[:])
}

// Discover source files for packaging.
discover_sources :: proc(project_dir: string, allocator: mem.Allocator) -> (Source_Files, Platform_Error) {
	result := Source_Files{
		files    = make([dynamic]string, 0, 64, allocator),
		packages = make([dynamic]string, 0, 8, allocator),
	}

	// Check for src/ layout
	src_dir := strings.concatenate({project_dir, "/src"}, allocator)
	if os.is_directory(src_dir) {
		entries, dir_err := os.read_all_directory_by_path(src_dir, allocator)
		if dir_err == nil {
			for entry in entries {
				if entry.type == .Directory && !_build_excluded_dir(entry.name) {
					init_path := strings.concatenate({src_dir, "/", entry.name, "/__init__.py"}, allocator)
					if os.is_file(init_path) {
						result.root = src_dir
						break
					}
				}
			}
		}
	}

	if result.root == "" {
		result.root = project_dir
	}

	// Scan for packages and top-level modules
	entries, dir_err := os.read_all_directory_by_path(result.root, allocator)
	if dir_err != nil {
		return result, Platform_Error_Data{msg = fmt.tprintf("cannot read source directory '%s': %v", result.root, dir_err)}
	}

	for entry in entries {
		if entry.type == .Directory {
			if _build_excluded_dir(entry.name) { continue }
			init_path := strings.concatenate({result.root, "/", entry.name, "/__init__.py"}, allocator)
			if os.is_file(init_path) {
				append(&result.packages, strings.clone(entry.name, allocator))
				_collect_pkg_files(&result.files, result.root, entry.name, allocator)
			}
		} else {
			if strings.has_suffix(entry.name, ".py") && !_build_excluded_file(entry.name) {
				append(&result.files, strings.clone(entry.name, allocator))
			}
		}
	}

	if len(result.packages) == 0 && len(result.files) == 0 {
		return result, Platform_Error_Data{msg = "no Python packages or modules found"}
	}

	return result, nil
}

// Generate PEP 566 METADATA content.
generate_metadata :: proc(cfg: ^Build_Config, allocator: mem.Allocator) -> string {
	b := strings.builder_make(0, 512, allocator)

	strings.write_string(&b, "Metadata-Version: 2.1\n")
	strings.write_string(&b, "Name: ")
	strings.write_string(&b, cfg.name)
	strings.write_byte(&b, '\n')
	strings.write_string(&b, "Version: ")
	strings.write_string(&b, cfg.version)
	strings.write_byte(&b, '\n')

	if cfg.description != "" {
		strings.write_string(&b, "Summary: ")
		strings.write_string(&b, cfg.description)
		strings.write_byte(&b, '\n')
	}

	if cfg.author_email != "" {
		strings.write_string(&b, "Author-email: ")
		if cfg.author != "" {
			strings.write_string(&b, cfg.author)
			strings.write_string(&b, " <")
			strings.write_string(&b, cfg.author_email)
			strings.write_byte(&b, '>')
		} else {
			strings.write_string(&b, cfg.author_email)
		}
		strings.write_byte(&b, '\n')
	} else if cfg.author != "" {
		strings.write_string(&b, "Author: ")
		strings.write_string(&b, cfg.author)
		strings.write_byte(&b, '\n')
	}

	if cfg.license_text != "" {
		strings.write_string(&b, "License: ")
		strings.write_string(&b, cfg.license_text)
		strings.write_byte(&b, '\n')
	}

	if cfg.requires_python != "" {
		strings.write_string(&b, "Requires-Python: ")
		strings.write_string(&b, cfg.requires_python)
		strings.write_byte(&b, '\n')
	}

	for dep in cfg.dependencies {
		strings.write_string(&b, "Requires-Dist: ")
		strings.write_string(&b, dep.raw)
		strings.write_byte(&b, '\n')
	}

	// Inline README if present
	if cfg.readme_path != "" {
		readme_abs := strings.concatenate({cfg.project_dir, "/", cfg.readme_path}, allocator)
		readme_data, readme_err := os.read_entire_file(readme_abs, allocator)
		if readme_err == nil && len(readme_data) > 0 {
			if strings.has_suffix(cfg.readme_path, ".md") {
				strings.write_string(&b, "Description-Content-Type: text/markdown\n")
			} else if strings.has_suffix(cfg.readme_path, ".rst") {
				strings.write_string(&b, "Description-Content-Type: text/x-rst\n")
			} else {
				strings.write_string(&b, "Description-Content-Type: text/plain\n")
			}
			strings.write_byte(&b, '\n')
			strings.write_string(&b, string(readme_data))
			if readme_data[len(readme_data) - 1] != '\n' {
				strings.write_byte(&b, '\n')
			}
		}
	}

	return strings.to_string(b)
}

// Build wheel (.whl) — PEP 427.
build_wheel :: proc(
	cfg: ^Build_Config,
	sources: ^Source_Files,
	python: string,
	output_dir: string,
	allocator: mem.Allocator,
) -> (string, Platform_Error) {
	norm_name := normalize_name(cfg.name, allocator)
	dist_info := strings.concatenate({norm_name, "-", cfg.version, ".dist-info"}, allocator)
	whl_name := strings.concatenate({norm_name, "-", cfg.version, "-py3-none-any.whl"}, allocator)

	// Create staging directory
	tmp, tmp_err := os.temp_directory(allocator)
	if tmp_err != nil { tmp = "/tmp" }
	stage_dir := strings.concatenate({tmp, "/mimir-wheel-", norm_name, "-", cfg.version}, allocator)

	// Clean previous staging
	_rm_rf(stage_dir, allocator)
	mk_err := os.make_directory_all(stage_dir)
	if mk_err != nil {
		return "", Platform_Error_Data{msg = fmt.tprintf("cannot create staging dir: %v", mk_err)}
	}

	// Copy source files
	for f in sources.files {
		src_path := strings.concatenate({sources.root, "/", f}, allocator)
		dst_path := strings.concatenate({stage_dir, "/", f}, allocator)
		os.make_directory_all(parent_dir(dst_path))

		data, read_err := os.read_entire_file(src_path, allocator)
		if read_err != nil {
			return "", Platform_Error_Data{msg = fmt.tprintf("cannot read '%s': %v", src_path, read_err)}
		}
		write_err := os.write_entire_file(dst_path, data)
		if write_err != nil {
			return "", Platform_Error_Data{msg = fmt.tprintf("cannot write '%s': %v", dst_path, write_err)}
		}
	}

	// Create dist-info directory
	dist_info_dir := strings.concatenate({stage_dir, "/", dist_info}, allocator)
	os.make_directory_all(dist_info_dir)

	// Write METADATA
	metadata := generate_metadata(cfg, allocator)
	_ = os.write_entire_file(
		strings.concatenate({dist_info_dir, "/METADATA"}, allocator),
		transmute([]u8)metadata,
	)

	// Write WHEEL
	_ = os.write_entire_file(
		strings.concatenate({dist_info_dir, "/WHEEL"}, allocator),
		transmute([]u8)_wheel_metadata(allocator),
	)

	// Write top_level.txt
	_ = os.write_entire_file(
		strings.concatenate({dist_info_dir, "/top_level.txt"}, allocator),
		transmute([]u8)_top_level_txt(sources, allocator),
	)

	// Write entry_points.txt if scripts defined
	ep := _entry_points_txt(cfg, allocator)
	if ep != "" {
		_ = os.write_entire_file(
			strings.concatenate({dist_info_dir, "/entry_points.txt"}, allocator),
			transmute([]u8)ep,
		)
	}

	// Generate RECORD via Python helper
	record_script := strings.concatenate({
		"import hashlib,base64,os,pathlib,sys\n",
		"os.chdir(sys.argv[1])\n",
		"di=sys.argv[2]\n",
		"lines=[]\n",
		"for r,ds,fs in os.walk('.'):\n",
		" ds[:]=sorted(d for d in ds if not d.startswith('.'))\n",
		" for f in sorted(fs):\n",
		"  p=os.path.join(r,f);rel=os.path.relpath(p).replace(os.sep,'/')\n",
		"  if rel==di+'/RECORD':continue\n",
		"  d=pathlib.Path(p).read_bytes()\n",
		"  h='sha256='+base64.urlsafe_b64encode(hashlib.sha256(d).digest()).rstrip(b'=').decode()\n",
		"  lines.append(f'{rel},{h},{len(d)}')\n",
		"lines.append(f'{di}/RECORD,,')\n",
		"lines.sort()\n",
		"pathlib.Path(os.path.join(di,'RECORD')).write_text('\\n'.join(lines)+'\\n')\n",
	}, allocator)

	rec_state, _, rec_stderr, rec_err := os.process_exec({
		command = {python, "-c", record_script, stage_dir, dist_info},
	}, allocator)
	if rec_err != nil || rec_state.exit_code != 0 {
		err_msg := string(rec_stderr) if len(rec_stderr) > 0 else "unknown error"
		return "", Platform_Error_Data{msg = fmt.tprintf("RECORD generation failed: %s", strings.trim_space(err_msg))}
	}

	// Create output directory
	os.make_directory_all(output_dir)

	// Create wheel via zip (run inside staging directory)
	whl_path := strings.concatenate({output_dir, "/", whl_name}, allocator)
	zip_cmd := fmt.tprintf("cd '%s' && zip -r -q '%s' .", stage_dir, whl_path)
	zip_state, _, zip_stderr, zip_err := os.process_exec({
		command = {"bash", "-c", zip_cmd},
	}, allocator)
	if zip_err != nil || zip_state.exit_code != 0 {
		err_msg := string(zip_stderr) if len(zip_stderr) > 0 else "unknown error"
		return "", Platform_Error_Data{msg = fmt.tprintf("wheel creation failed: %s", strings.trim_space(err_msg))}
	}

	// Clean up staging
	_rm_rf(stage_dir, allocator)

	return whl_path, nil
}

// Build sdist (.tar.gz) — PEP 625.
build_sdist :: proc(
	cfg: ^Build_Config,
	sources: ^Source_Files,
	output_dir: string,
	allocator: mem.Allocator,
) -> (string, Platform_Error) {
	sdist_name := strings.concatenate({cfg.name, "-", cfg.version}, allocator)
	tarball_name := strings.concatenate({sdist_name, ".tar.gz"}, allocator)

	// Create staging: base/name-version/
	tmp, tmp_err := os.temp_directory(allocator)
	if tmp_err != nil { tmp = "/tmp" }
	stage_base := strings.concatenate({tmp, "/mimir-sdist-", cfg.name, "-", cfg.version}, allocator)
	stage_dir := strings.concatenate({stage_base, "/", sdist_name}, allocator)

	_rm_rf(stage_base, allocator)
	os.make_directory_all(stage_dir)

	// Copy source files
	for f in sources.files {
		src_path := strings.concatenate({sources.root, "/", f}, allocator)
		dst_path := strings.concatenate({stage_dir, "/", f}, allocator)
		os.make_directory_all(parent_dir(dst_path))

		data, read_err := os.read_entire_file(src_path, allocator)
		if read_err != nil {
			return "", Platform_Error_Data{msg = fmt.tprintf("cannot read '%s': %v", src_path, read_err)}
		}
		_ = os.write_entire_file(dst_path, data)
	}

	// Write PKG-INFO (same format as METADATA)
	metadata := generate_metadata(cfg, allocator)
	_ = os.write_entire_file(
		strings.concatenate({stage_dir, "/PKG-INFO"}, allocator),
		transmute([]u8)metadata,
	)

	// Copy mimir.toml
	mimir_toml := strings.concatenate({cfg.project_dir, "/mimir.toml"}, allocator)
	if os.is_file(mimir_toml) {
		data, rd_err := os.read_entire_file(mimir_toml, allocator)
		if rd_err == nil && len(data) > 0 {
			_ = os.write_entire_file(strings.concatenate({stage_dir, "/mimir.toml"}, allocator), data)
		}
	}

	// Copy README if specified
	if cfg.readme_path != "" {
		readme_src := strings.concatenate({cfg.project_dir, "/", cfg.readme_path}, allocator)
		if os.is_file(readme_src) {
			data, rd_err := os.read_entire_file(readme_src, allocator)
			if rd_err == nil && len(data) > 0 {
				_ = os.write_entire_file(
					strings.concatenate({stage_dir, "/", cfg.readme_path}, allocator),
					data,
				)
			}
		}
	}

	// Create output directory + tarball
	os.make_directory_all(output_dir)
	tarball_path := strings.concatenate({output_dir, "/", tarball_name}, allocator)

	tar_state, _, tar_stderr, tar_err := os.process_exec({
		command = {"tar", "czf", tarball_path, "-C", stage_base, sdist_name},
	}, allocator)
	if tar_err != nil || tar_state.exit_code != 0 {
		err_msg := string(tar_stderr) if len(tar_stderr) > 0 else "unknown error"
		return "", Platform_Error_Data{msg = fmt.tprintf("sdist creation failed: %s", strings.trim_space(err_msg))}
	}

	// Clean up staging
	_rm_rf(stage_base, allocator)

	return tarball_path, nil
}

// Build both wheel and sdist. Cleans output_dir first.
build_all :: proc(
	cfg: ^Build_Config,
	sources: ^Source_Files,
	python: string,
	output_dir: string,
	allocator: mem.Allocator,
) -> Platform_Error {
	_rm_rf(output_dir, allocator)

	whl_path, whl_err := build_wheel(cfg, sources, python, output_dir, allocator)
	if whl_err != nil { return whl_err }
	fmt.printfln("  built %s", whl_path)

	sdist_path, sdist_err := build_sdist(cfg, sources, output_dir, allocator)
	if sdist_err != nil { return sdist_err }
	fmt.printfln("  built %s", sdist_path)

	return nil
}

// ---- Private helpers ----

@(private = "file")
_rm_rf :: proc(path: string, allocator: mem.Allocator) {
	state, _, _, exec_err := os.process_exec({
		command = {"rm", "-rf", path},
	}, allocator)
	_ = state
	_ = exec_err
}

@(private = "file")
_wheel_metadata :: proc(allocator: mem.Allocator) -> string {
	return strings.clone(
		"Wheel-Version: 1.0\nGenerator: mimir\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
		allocator,
	)
}

@(private = "file")
_top_level_txt :: proc(sources: ^Source_Files, allocator: mem.Allocator) -> string {
	b := strings.builder_make(0, 64, allocator)
	for pkg in sources.packages {
		strings.write_string(&b, pkg)
		strings.write_byte(&b, '\n')
	}
	for f in sources.files {
		if !strings.contains(f, "/") && strings.has_suffix(f, ".py") {
			strings.write_string(&b, f[:len(f) - 3])
			strings.write_byte(&b, '\n')
		}
	}
	return strings.to_string(b)
}

@(private = "file")
_entry_points_txt :: proc(cfg: ^Build_Config, allocator: mem.Allocator) -> string {
	if len(cfg.scripts) == 0 { return "" }
	b := strings.builder_make(0, 128, allocator)
	strings.write_string(&b, "[console_scripts]\n")
	for ep in cfg.scripts {
		strings.write_string(&b, ep.name)
		strings.write_string(&b, " = ")
		strings.write_string(&b, ep.ref)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

@(private = "file")
_collect_pkg_files :: proc(files: ^[dynamic]string, root: string, rel_dir: string, allocator: mem.Allocator) {
	abs_dir := strings.concatenate({root, "/", rel_dir}, allocator)
	entries, dir_err := os.read_all_directory_by_path(abs_dir, allocator)
	if dir_err != nil { return }

	for entry in entries {
		rel_path := strings.concatenate({rel_dir, "/", entry.name}, allocator)
		if entry.type == .Directory {
			if _build_excluded_dir(entry.name) { continue }
			_collect_pkg_files(files, root, rel_path, allocator)
		} else {
			if _build_excluded_file(entry.name) { continue }
			append(files, rel_path)
		}
	}
}

@(private = "file")
_build_excluded_dir :: proc(name: string) -> bool {
	switch name {
	case "__pycache__", ".git", ".mimir", "dist", "build", ".tox", ".venv", ".eggs", "tests", "test":
		return true
	}
	if strings.has_suffix(name, ".egg-info") { return true }
	return false
}

@(private = "file")
_build_excluded_file :: proc(name: string) -> bool {
	if strings.has_suffix(name, ".pyc") || strings.has_suffix(name, ".pyo") { return true }
	if name == ".DS_Store" { return true }
	return false
}
