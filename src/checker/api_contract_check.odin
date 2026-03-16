package checker

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

import parser "mimir:parser"
import core   "mimir:core"

// ==================== API Contract Verification ====================
//
// Post-inference analysis pass for OpenAPI spec validation.
// Reads openapi.json, cross-references with discovered mimir.http routes,
// validates handler response fields against spec.
//
// Diagnostics:
//   API001 — Response field not in OpenAPI spec
//   API002 — Required field missing from response
//   API003 — Route not in OpenAPI spec

API_Spec_Route :: struct {
	method:          string,
	path:            string,
	response_fields: map[string]bool,
	required_fields: map[string]bool,
}

// Entry point — called from checker.odin after analyze_routes.
analyze_api_contracts :: proc(
	module: ^parser.Module,
	routes: []Route_Info,
	file_path: string,
	diagnostics: ^[dynamic]core.Diagnostic,
	allocator: mem.Allocator,
) {
	// Find openapi.json relative to the source file
	spec_path := find_openapi_spec(file_path, allocator)
	if len(spec_path) == 0 { return }

	// Read and parse spec
	spec_data, read_err := os.read_entire_file(spec_path, allocator)
	if read_err != nil { return }

	parsed, parse_err := json.parse(spec_data, .JSON, true, allocator)
	if parse_err != nil { return }

	root, is_obj := parsed.(json.Object)
	if !is_obj { return }

	// Extract spec routes from paths
	spec_routes := extract_spec_routes(root, allocator)
	if len(spec_routes) == 0 { return }

	// Cross-reference code routes against spec
	for &route in routes {
		method_upper := strings.to_upper(route.method, context.temp_allocator)
		spec_key := fmt.tprintf("%s %s", method_upper, route.path)

		spec_route, found := spec_routes[spec_key]
		if !found {
			// API003: route not in spec
			append(diagnostics, core.Diagnostic{
				severity = .Warning,
				location = core.Location{
					file   = file_path,
					line   = int(route.handler_loc.line),
					column = int(route.handler_loc.col),
				},
				what = fmt.tprintf("route %s %s not found in OpenAPI spec", route.method, route.path),
				why  = "handler defines a route not documented in openapi.json",
				fix  = "add the route to openapi.json or remove the handler",
				code = "API003",
			})
			continue
		}

		// Find handler function and extract response dict keys
		handler_keys := extract_handler_response_keys(module, route.handler_name, allocator)
		if len(handler_keys) == 0 { continue }

		// API001: response field not in spec
		for key in handler_keys {
			if key not_in spec_route.response_fields {
				append(diagnostics, core.Diagnostic{
					severity = .Error,
					location = core.Location{
						file   = file_path,
						line   = int(route.handler_loc.line),
						column = int(route.handler_loc.col),
					},
					what = fmt.tprintf("response field \"%s\" not in OpenAPI spec for %s %s", key, route.method, route.path),
					why  = "handler returns a field not documented in the API specification",
					fix  = fmt.tprintf("remove \"%s\" from the response or add it to the spec", key),
					code = "API001",
				})
			}
		}

		// API002: required field missing from response
		for req_field in spec_route.required_fields {
			if req_field not_in handler_keys {
				append(diagnostics, core.Diagnostic{
					severity = .Warning,
					location = core.Location{
						file   = file_path,
						line   = int(route.handler_loc.line),
						column = int(route.handler_loc.col),
					},
					what = fmt.tprintf("required field \"%s\" missing from response for %s %s", req_field, route.method, route.path),
					why  = "OpenAPI spec requires this field but handler response does not include it",
					fix  = fmt.tprintf("add \"%s\" to the response dict", req_field),
					code = "API002",
				})
			}
		}
	}
}

// ==================== OpenAPI Spec Parsing ====================

find_openapi_spec :: proc(file_path: string, allocator: mem.Allocator) -> string {
	// Look for openapi.json in same directory as the source file
	dir := file_path
	for i := len(dir) - 1; i >= 0; i -= 1 {
		if dir[i] == '/' {
			dir = dir[:i]
			break
		}
	}

	candidate := fmt.tprintf("%s/openapi.json", dir)
	if os.exists(candidate) { return candidate }

	return ""
}

extract_spec_routes :: proc(root: json.Object, allocator: mem.Allocator) -> map[string]API_Spec_Route {
	result := make(map[string]API_Spec_Route, 16, allocator)

	paths_val, has_paths := root["paths"]
	if !has_paths { return result }
	paths, is_paths_obj := paths_val.(json.Object)
	if !is_paths_obj { return result }

	for path_str, path_val in paths {
		path_obj, is_obj := path_val.(json.Object)
		if !is_obj { continue }

		METHODS :: [?]string{"get", "post", "put", "patch", "delete", "head", "options"}
		for method in METHODS {
			method_val, has_method := path_obj[method]
			if !has_method { continue }
			method_obj, is_method_obj := method_val.(json.Object)
			if !is_method_obj { continue }

			response_fields := make(map[string]bool, 8, allocator)
			required_fields := make(map[string]bool, 8, allocator)

			// Navigate: responses → 200 → content → application/json → schema → properties
			extract_response_schema(method_obj, &response_fields, &required_fields)

			method_upper := strings.to_upper(method, context.temp_allocator)
			key := fmt.aprintf("%s %s", method_upper, path_str, allocator = allocator)
			result[key] = API_Spec_Route{
				method          = method_upper,
				path            = path_str,
				response_fields = response_fields,
				required_fields = required_fields,
			}
		}
	}

	return result
}

extract_response_schema :: proc(method_obj: json.Object, response_fields: ^map[string]bool, required_fields: ^map[string]bool) {
	responses_val, has_resp := method_obj["responses"]
	if !has_resp { return }
	responses, is_resp_obj := responses_val.(json.Object)
	if !is_resp_obj { return }

	// Try 200, then 201, then first 2xx
	STATUS_CODES :: [?]string{"200", "201", "202"}
	resp_obj: json.Object
	found_resp := false
	for code in STATUS_CODES {
		if rv, ok := responses[code]; ok {
			if ro, ro_ok := rv.(json.Object); ro_ok {
				resp_obj = ro
				found_resp = true
				break
			}
		}
	}
	if !found_resp { return }

	content_val, has_content := resp_obj["content"]
	if !has_content { return }
	content, is_content_obj := content_val.(json.Object)
	if !is_content_obj { return }

	json_val, has_json := content["application/json"]
	if !has_json { return }
	json_obj, is_json_obj := json_val.(json.Object)
	if !is_json_obj { return }

	schema_val, has_schema := json_obj["schema"]
	if !has_schema { return }
	schema, is_schema_obj := schema_val.(json.Object)
	if !is_schema_obj { return }

	// Extract properties
	props_val, has_props := schema["properties"]
	if !has_props { return }
	props, is_props_obj := props_val.(json.Object)
	if !is_props_obj { return }

	for prop_name in props {
		response_fields[prop_name] = true
	}

	// Extract required fields
	req_val, has_req := schema["required"]
	if !has_req { return }
	req_arr, is_arr := req_val.(json.Array)
	if !is_arr { return }

	for rv in req_arr {
		if s, s_ok := rv.(json.String); s_ok {
			required_fields[s] = true
		}
	}
}

// ==================== Handler Response Extraction ====================

extract_handler_response_keys :: proc(module: ^parser.Module, handler_name: string, allocator: mem.Allocator) -> map[string]bool {
	keys := make(map[string]bool, 8, allocator)

	// Find the handler function
	for stmt in module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			if s.name == handler_name {
				collect_return_dict_keys(s.body, &keys)
				return keys
			}
		case ^parser.Async_Func_Def:
			if s.name == handler_name {
				collect_return_dict_keys(s.body, &keys)
				return keys
			}
		}
	}

	return keys
}

collect_return_dict_keys :: proc(body: []parser.Stmt, keys: ^map[string]bool) {
	for stmt in body {
		#partial switch s in stmt {
		case ^parser.Return_Stmt:
			if s.value != nil {
				extract_dict_keys_from_expr(s.value, keys)
			}

		// Recurse into control flow
		case ^parser.If_Stmt:
			collect_return_dict_keys(s.body, keys)
			collect_return_dict_keys(s.orelse, keys)
		case ^parser.For_Stmt:
			collect_return_dict_keys(s.body, keys)
		case ^parser.While_Stmt:
			collect_return_dict_keys(s.body, keys)
		case ^parser.With_Stmt:
			collect_return_dict_keys(s.body, keys)
		case ^parser.Try_Stmt:
			collect_return_dict_keys(s.body, keys)
			collect_return_dict_keys(s.orelse, keys)
			for &handler in s.handlers {
				collect_return_dict_keys(handler.body, keys)
			}
		}
	}
}

extract_dict_keys_from_expr :: proc(expr: parser.Expr, keys: ^map[string]bool) {
	// Direct dict literal: return {"key": value}
	if dict, ok := expr.(^parser.Dict_Expr); ok {
		for k in dict.keys {
			if c, c_ok := k.(^parser.Constant_Expr); c_ok {
				if s, s_ok := c.value.(string); s_ok {
					keys[s] = true
				}
			}
		}
		return
	}

	// Response(body={"key": value}) or Response({"key": value})
	if call, ok := expr.(^parser.Call_Expr); ok {
		// Check keyword arg body=
		for kw in call.keywords {
			if kw.arg == "body" {
				extract_dict_keys_from_expr(kw.value, keys)
				return
			}
		}
		// Check first positional arg for dict
		if len(call.args) >= 1 {
			if _, is_dict := call.args[0].(^parser.Dict_Expr); is_dict {
				extract_dict_keys_from_expr(call.args[0], keys)
			}
		}
	}
}
