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
//   API004 — Response field type mismatch (spec says integer, handler returns string)
//   API005 — Handler does not read required request body

API_Spec_Route :: struct {
	method:          string,
	path:            string,
	response_fields: map[string]bool,
	required_fields: map[string]bool,
	field_types:     map[string]string, // field_name → OpenAPI type ("integer", "string", etc.)
	has_request_body: bool,
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

		// API004: response field type mismatch
		handler_types := extract_handler_response_types(module, route.handler_name, allocator)
		for key, py_type in handler_types {
			if spec_type, has_st := spec_route.field_types[key]; has_st {
				expected_py := openapi_type_to_python(spec_type)
				if len(expected_py) > 0 && expected_py != py_type {
					append(diagnostics, core.Diagnostic{
						severity = .Warning,
						location = core.Location{
							file   = file_path,
							line   = int(route.handler_loc.line),
							column = int(route.handler_loc.col),
						},
						what = fmt.tprintf("response field \"%s\" type mismatch: handler returns %s, spec expects %s", key, py_type, spec_type),
						why  = "handler returns a value whose type does not match the OpenAPI specification",
						fix  = fmt.tprintf("change the value to match the spec type (%s)", spec_type),
						code = "API004",
					})
				}
			}
		}

		// API005: handler does not read required request body
		if spec_route.has_request_body {
			if !handler_reads_request_body(module, route.handler_name) {
				append(diagnostics, core.Diagnostic{
					severity = .Warning,
					location = core.Location{
						file   = file_path,
						line   = int(route.handler_loc.line),
						column = int(route.handler_loc.col),
					},
					what = fmt.tprintf("handler %s does not read request body for %s %s", route.handler_name, route.method, route.path),
					why  = "OpenAPI spec declares a requestBody but handler does not access req.json or req.body",
					fix  = "add request body parsing (e.g., data = req.json) or remove requestBody from spec",
					code = "API005",
				})
			}
		}
	}
}

// Map OpenAPI type strings to Python type names for comparison.
openapi_type_to_python :: proc(openapi_type: string) -> string {
	switch openapi_type {
	case "integer": return "int"
	case "string":  return "str"
	case "number":  return "float"
	case "boolean": return "bool"
	case "array":   return "list"
	case "object":  return "dict"
	}
	return ""
}

// ==================== OpenAPI Spec Parsing ====================

find_openapi_spec :: proc(file_path: string, allocator: mem.Allocator) -> string {
	// Look for openapi.json/yaml in same directory as the source file
	dir := file_path
	for i := len(dir) - 1; i >= 0; i -= 1 {
		if dir[i] == '/' {
			dir = dir[:i]
			break
		}
	}

	// Search for openapi.json first, then YAML variants
	SPEC_NAMES :: [?]string{"openapi.json", "openapi.yaml", "openapi.yml"}
	for name in SPEC_NAMES {
		candidate := fmt.tprintf("%s/%s", dir, name)
		if os.exists(candidate) {
			if strings.has_suffix(name, ".json") {
				return candidate
			}
			// YAML found — convert to JSON via Python
			json_path := _convert_yaml_to_json(candidate, allocator)
			if len(json_path) > 0 { return json_path }
		}
	}

	return ""
}

// Convert a YAML file to JSON using Python's yaml + json modules.
// Returns path to temp JSON file, or "" if conversion fails.
@(private = "file")
_convert_yaml_to_json :: proc(yaml_path: string, allocator: mem.Allocator) -> string {
	pid := os.get_pid()
	json_path := fmt.aprintf("/tmp/mimir_openapi_%d.json", pid, allocator = allocator)
	script := fmt.tprintf(
		"import yaml, json, sys; data = yaml.safe_load(open('%s')); json.dump(data, open('%s', 'w'))",
		yaml_path, json_path)

	state, _, _, exec_err := os.process_exec({
		command = {"python3", "-c", script},
	}, allocator)
	if exec_err != nil || state.exit_code != 0 {
		return ""
	}
	if os.is_file(json_path) {
		return json_path
	}
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
			field_types := make(map[string]string, 8, allocator)

			// Navigate: responses → 200 → content → application/json → schema → properties
			extract_response_schema(method_obj, &response_fields, &required_fields, &field_types)

			// Check for requestBody
			has_req_body := false
			if _, has_rb := method_obj["requestBody"]; has_rb {
				has_req_body = true
			}

			method_upper := strings.to_upper(method, context.temp_allocator)
			key := fmt.aprintf("%s %s", method_upper, path_str, allocator = allocator)
			result[key] = API_Spec_Route{
				method           = method_upper,
				path             = path_str,
				response_fields  = response_fields,
				required_fields  = required_fields,
				field_types      = field_types,
				has_request_body = has_req_body,
			}
		}
	}

	return result
}

extract_response_schema :: proc(method_obj: json.Object, response_fields: ^map[string]bool, required_fields: ^map[string]bool, field_types: ^map[string]string = nil) {
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

	for prop_name, prop_val in props {
		response_fields[prop_name] = true
		// Extract type for API004 validation
		if field_types != nil {
			if prop_obj, p_ok := prop_val.(json.Object); p_ok {
				if type_val, has_type := prop_obj["type"]; has_type {
					if type_str, t_ok := type_val.(json.String); t_ok {
						field_types[prop_name] = type_str
					}
				}
			}
		}
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

// Extract response dict key→type from handler return statements.
// Returns map like {"id": "int", "name": "str"} based on literal value types.
extract_handler_response_types :: proc(module: ^parser.Module, handler_name: string, allocator: mem.Allocator) -> map[string]string {
	types := make(map[string]string, 8, allocator)
	for stmt in module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			if s.name == handler_name {
				collect_return_dict_types(s.body, &types)
				return types
			}
		case ^parser.Async_Func_Def:
			if s.name == handler_name {
				collect_return_dict_types(s.body, &types)
				return types
			}
		}
	}
	return types
}

collect_return_dict_types :: proc(body: []parser.Stmt, types: ^map[string]string) {
	for stmt in body {
		#partial switch s in stmt {
		case ^parser.Return_Stmt:
			if s.value != nil {
				extract_dict_types_from_expr(s.value, types)
			}
		case ^parser.If_Stmt:
			collect_return_dict_types(s.body, types)
			collect_return_dict_types(s.orelse, types)
		}
	}
}

extract_dict_types_from_expr :: proc(expr: parser.Expr, types: ^map[string]string) {
	// Direct dict literal: return {"key": value}
	if dict, ok := expr.(^parser.Dict_Expr); ok {
		for k, i in dict.keys {
			if c, c_ok := k.(^parser.Constant_Expr); c_ok {
				if s, s_ok := c.value.(string); s_ok {
					if i < len(dict.values) {
						types[s] = infer_literal_type(dict.values[i])
					}
				}
			}
		}
		return
	}
	// Response(body={"key": value})
	if call, ok := expr.(^parser.Call_Expr); ok {
		for kw in call.keywords {
			if kw.arg == "body" {
				extract_dict_types_from_expr(kw.value, types)
				return
			}
		}
		if len(call.args) >= 1 {
			extract_dict_types_from_expr(call.args[0], types)
		}
	}
}

// Infer Python type name from a literal expression.
infer_literal_type :: proc(expr: parser.Expr) -> string {
	#partial switch e in expr {
	case ^parser.Constant_Expr:
		#partial switch _ in e.value {
		case i64:    return "int"
		case f64:    return "float"
		case string: return "str"
		case bool:   return "bool"
		}
	case ^parser.List_Expr:
		return "list"
	case ^parser.Dict_Expr:
		return "dict"
	}
	return ""
}

// Check if a handler function reads the request body (req.json, req.body, req.data).
handler_reads_request_body :: proc(module: ^parser.Module, handler_name: string) -> bool {
	for stmt in module.body {
		#partial switch s in stmt {
		case ^parser.Func_Def:
			if s.name == handler_name {
				return _body_reads_request(s.body)
			}
		case ^parser.Async_Func_Def:
			if s.name == handler_name {
				return _body_reads_request(s.body)
			}
		}
	}
	return false
}

_body_reads_request :: proc(body: []parser.Stmt) -> bool {
	for stmt in body {
		#partial switch s in stmt {
		case ^parser.Assign:
			if _expr_reads_request(s.value) { return true }
		case ^parser.Ann_Assign:
			if s.value != nil && _expr_reads_request(s.value) { return true }
		case ^parser.Expr_Stmt:
			if _expr_reads_request(s.value) { return true }
		case ^parser.If_Stmt:
			if _body_reads_request(s.body) || _body_reads_request(s.orelse) { return true }
		case ^parser.Return_Stmt:
			if s.value != nil && _expr_reads_request(s.value) { return true }
		}
	}
	return false
}

_expr_reads_request :: proc(expr: parser.Expr) -> bool {
	if expr == nil { return false }
	// req.json, req.body, req.data, request.json, etc.
	if attr, ok := expr.(^parser.Attribute_Expr); ok {
		if name, n_ok := attr.value.(^parser.Name_Expr); n_ok {
			if name.id == "req" || name.id == "request" {
				if attr.attr == "json" || attr.attr == "body" || attr.attr == "data" || attr.attr == "form" {
					return true
				}
			}
		}
	}
	// Recurse into calls: e.g., req.json()
	if call, ok := expr.(^parser.Call_Expr); ok {
		if _expr_reads_request(call.func) { return true }
	}
	return false
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
