package platform

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// PyPI package publisher — uploads built packages to a package index.

Publish_Config :: struct {
	index_url: string,
	token:     string,
}

// Find PyPI credentials from environment or ~/.pypirc.
find_credentials :: proc(allocator: mem.Allocator) -> (Publish_Config, Platform_Error) {
	cfg := Publish_Config{
		index_url = "https://upload.pypi.org/legacy/",
	}

	// Check MIMIR_PYPI_TOKEN first
	if token, ok := os.lookup_env("MIMIR_PYPI_TOKEN", allocator); ok && token != "" {
		cfg.token = token
		return cfg, nil
	}

	// Check TWINE_PASSWORD (compatibility)
	if token, ok := os.lookup_env("TWINE_PASSWORD", allocator); ok && token != "" {
		cfg.token = token
		return cfg, nil
	}

	// Check ~/.pypirc
	home, home_err := os.user_home_dir(allocator)
	if home_err == nil {
		pypirc_path := strings.concatenate({home, "/.pypirc"}, allocator)
		if os.is_file(pypirc_path) {
			data, read_err := os.read_entire_file(pypirc_path, allocator)
			if read_err == nil {
				token := _parse_pypirc_token(string(data), allocator)
				if token != "" {
					cfg.token = token
					return cfg, nil
				}
			}
		}
	}

	return {}, Platform_Error_Data{
		msg = "no PyPI credentials found; set MIMIR_PYPI_TOKEN or TWINE_PASSWORD, or create ~/.pypirc",
	}
}

// Upload a single file to PyPI.
publish_file :: proc(cfg: ^Publish_Config, file_path: string, allocator: mem.Allocator) -> Platform_Error {
	if !os.is_file(file_path) {
		return Platform_Error_Data{msg = fmt.tprintf("file not found: %s", file_path)}
	}

	fmt.printfln("  uploading %s...", file_path)

	// Write auth header to temp config file to avoid exposing token in process args
	tmp_dir, tmp_err := os.temp_directory(allocator)
	if tmp_err != nil { tmp_dir = "/tmp" }
	curl_cfg_path := strings.concatenate({tmp_dir, "/mimir_curl_cfg"}, allocator)
	curl_cfg_content := fmt.tprintf("header = \"Authorization: Bearer %s\"", cfg.token)
	cfg_write_err := os.write_entire_file(curl_cfg_path, transmute([]byte)curl_cfg_content)
	if cfg_write_err != nil {
		return Platform_Error_Data{msg = fmt.tprintf("failed to write curl config: %v", cfg_write_err)}
	}
	defer os.remove(curl_cfg_path)

	content_field := fmt.tprintf("content=@%s", file_path)

	state, _, stderr_data, exec_err := os.process_exec({
		command = {
			"curl", "-X", "POST", cfg.index_url,
			"-K", curl_cfg_path,
			"-F", ":action=file_upload",
			"-F", "protocol_version=1",
			"-F", content_field,
			"--fail", "--silent", "--show-error",
		},
	}, allocator)
	if exec_err != nil {
		return Platform_Error_Data{msg = fmt.tprintf("failed to run curl: %v", exec_err)}
	}
	if state.exit_code != 0 {
		err_msg := strings.trim_space(string(stderr_data))
		return Platform_Error_Data{msg = fmt.tprintf("upload failed: %s", err_msg)}
	}

	return nil
}

// Upload all .whl and .tar.gz files in a directory.
publish_dist :: proc(cfg: ^Publish_Config, dist_dir: string, allocator: mem.Allocator) -> Platform_Error {
	if !os.is_directory(dist_dir) {
		return Platform_Error_Data{msg = fmt.tprintf("dist directory not found: %s", dist_dir)}
	}

	entries, dir_err := os.read_all_directory_by_path(dist_dir, allocator)
	if dir_err != nil {
		return Platform_Error_Data{msg = fmt.tprintf("cannot read '%s': %v", dist_dir, dir_err)}
	}

	uploaded := 0
	for entry in entries {
		if entry.type == .Directory { continue }
		if !strings.has_suffix(entry.name, ".whl") && !strings.has_suffix(entry.name, ".tar.gz") {
			continue
		}
		file_path := strings.concatenate({dist_dir, "/", entry.name}, allocator)
		err := publish_file(cfg, file_path, allocator)
		if err != nil { return err }
		uploaded += 1
	}

	if uploaded == 0 {
		return Platform_Error_Data{msg = "no .whl or .tar.gz files found in dist/"}
	}

	fmt.printfln("  uploaded %d file(s)", uploaded)
	return nil
}

// Parse a minimal .pypirc for the API token.
@(private = "file")
_parse_pypirc_token :: proc(content: string, allocator: mem.Allocator) -> string {
	lines := strings.split(content, "\n", allocator)
	in_pypi := false

	for line in lines {
		trimmed := strings.trim_space(line)
		if trimmed == "" || trimmed[0] == '#' { continue }

		if trimmed[0] == '[' {
			in_pypi = strings.has_prefix(trimmed, "[pypi]")
			continue
		}

		if in_pypi && strings.has_prefix(trimmed, "password") {
			eq := strings.index(trimmed, "=")
			if eq >= 0 {
				return strings.trim_space(trimmed[eq + 1:])
			}
		}
	}

	return ""
}
