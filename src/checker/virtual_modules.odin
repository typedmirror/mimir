package checker

import "core:mem"

import binder "mimir:binder"

// ==================== Virtual Module Registry ====================
//
// Pre-computed type stubs for mimir.* ecosystem modules. These resolve
// without any filesystem module — the types are built directly in the
// Type_Registry. Both single-file (check()) and multi-module
// (resolve_imports()) paths consult this registry.

Virtual_Module :: struct {
	name:             string,
	exports:          map[string]Type_ID,
	shape_semantics:  map[string]Shape_Semantic,
}

Virtual_Registry :: struct {
	modules: map[string]Virtual_Module,
}

// ==================== Initialization ====================

init_virtual_registry :: proc(reg: ^Type_Registry) -> Virtual_Registry {
	vreg: Virtual_Registry
	vreg.modules = make(map[string]Virtual_Module, 8, reg.allocator)

	// Register mimir.array
	register_mimir_array(&vreg, reg)

	// Register mimir.http
	register_mimir_http(&vreg, reg)

	return vreg
}

// ==================== Query Interface ====================

is_virtual_module :: proc(vreg: ^Virtual_Registry, module_name: string) -> bool {
	return module_name in vreg.modules
}

get_virtual_exports :: proc(vreg: ^Virtual_Registry, module_name: string) -> (map[string]Type_ID, bool) {
	if vm, ok := vreg.modules[module_name]; ok {
		return vm.exports, true
	}
	return {}, false
}

// Resolve virtual imports for a module's bind_result.
// Scans import records for mimir.* modules, returns symbol_id → type_id map.
// Also populates shape_reg with shape semantics for imported symbols.
resolve_virtual_imports :: proc(
	vreg: ^Virtual_Registry,
	bind_result: ^binder.Bind_Result,
	reg: ^Type_Registry,
	shape_reg: ^Shape_Registry = nil,
) -> map[binder.Symbol_ID]Type_ID {
	result := make(map[binder.Symbol_ID]Type_ID, 8, reg.allocator)

	mod_scope := binder.result_get_scope(bind_result, bind_result.module_scope)
	if mod_scope == nil { return result }

	for &imp in bind_result.imports {
		if !is_virtual_module(vreg, imp.module_name) { continue }

		vm, vm_ok := vreg.modules[imp.module_name]
		if !vm_ok { continue }

		if len(imp.names) == 0 {
			// "import mimir.array" — create Module_Type
			// The binder creates a symbol for the top-level "mimir"
			local_name := imp.module_name
			dot_idx := -1
			for i := 0; i < len(local_name); i += 1 {
				if local_name[i] == '.' {
					dot_idx = i
					break
				}
			}
			bound_name := local_name[:dot_idx] if dot_idx >= 0 else local_name

			if sym_id, found := mod_scope.symbols[bound_name]; found {
				module_type_id := register_type(reg, Module_Type{
					name    = imp.module_name,
					exports = vm.exports,
				})
				result[sym_id] = module_type_id
			}
		} else {
			// "from mimir.array import zeros, ones, ..."
			for imp_name in imp.names {
				local_name := imp_name.alias if len(imp_name.alias) > 0 else imp_name.name

				if sym_id, found := mod_scope.symbols[local_name]; found {
					if type_id, has := vm.exports[imp_name.name]; has {
						result[sym_id] = type_id
					}
					// Register shape semantic for this symbol
					if shape_reg != nil {
						if sem, has_sem := vm.shape_semantics[imp_name.name]; has_sem {
							shape_reg.semantics[sym_id] = sem
						}
					}
				}
			}
		}
	}

	return result
}

// ==================== mimir.array ====================

register_mimir_array :: proc(vreg: ^Virtual_Registry, reg: ^Type_Registry) {
	exports := make(map[string]Type_ID, 16, reg.allocator)

	// Tensor types for return values
	tensor_f64 := make_tensor_type(reg, TYPE_FLOAT, {})   // unknown shape
	tensor_int := make_tensor_type(reg, TYPE_INT, {})

	// Variadic tuple param for shape arguments
	shape_param := Param_Type{name = "shape", type_id = TYPE_ANY, has_default = false}
	dtype_param := Param_Type{name = "dtype", type_id = TYPE_ANY, has_default = true}

	// array(data) -> Tensor[f64]
	exports["array"] = make_callable_type(reg,
		{Param_Type{name = "data", type_id = TYPE_ANY}},
		tensor_f64,
	)

	// zeros(shape, dtype=f64) -> Tensor[f64]
	exports["zeros"] = make_callable_type(reg,
		{shape_param, dtype_param},
		tensor_f64,
	)

	// ones(shape, dtype=f64) -> Tensor[f64]
	exports["ones"] = make_callable_type(reg,
		{shape_param, dtype_param},
		tensor_f64,
	)

	// arange(start, stop, step) -> Tensor[int]
	exports["arange"] = make_callable_type(reg,
		{
			Param_Type{name = "start", type_id = TYPE_INT},
			Param_Type{name = "stop",  type_id = TYPE_INT, has_default = true},
			Param_Type{name = "step",  type_id = TYPE_INT, has_default = true},
		},
		tensor_int,
	)

	// linspace(start, stop, num) -> Tensor[f64]
	exports["linspace"] = make_callable_type(reg,
		{
			Param_Type{name = "start", type_id = TYPE_FLOAT},
			Param_Type{name = "stop",  type_id = TYPE_FLOAT},
			Param_Type{name = "num",   type_id = TYPE_INT, has_default = true},
		},
		tensor_f64,
	)

	// matmul(a, b) -> Tensor[f64]
	exports["matmul"] = make_callable_type(reg,
		{
			Param_Type{name = "a", type_id = tensor_f64},
			Param_Type{name = "b", type_id = tensor_f64},
		},
		tensor_f64,
	)

	// reshape(a, shape) -> Tensor[f64]
	exports["reshape"] = make_callable_type(reg,
		{
			Param_Type{name = "a",     type_id = tensor_f64},
			Param_Type{name = "shape", type_id = TYPE_ANY},
		},
		tensor_f64,
	)

	// sum(a) -> Tensor[f64]
	exports["sum"] = make_callable_type(reg,
		{Param_Type{name = "a", type_id = tensor_f64}},
		tensor_f64,
	)

	// mean(a) -> Tensor[f64]
	exports["mean"] = make_callable_type(reg,
		{Param_Type{name = "a", type_id = tensor_f64}},
		tensor_f64,
	)

	// transpose(a) -> Tensor[f64]
	exports["transpose"] = make_callable_type(reg,
		{Param_Type{name = "a", type_id = tensor_f64}},
		tensor_f64,
	)

	// Shape semantics for each export
	shape_sems := make(map[string]Shape_Semantic, 16, reg.allocator)
	shape_sems["zeros"]     = .Creation
	shape_sems["ones"]      = .Creation
	shape_sems["array"]     = .Creation
	shape_sems["linspace"]  = .Creation
	shape_sems["arange"]    = .Arange
	shape_sems["matmul"]    = .Matmul
	shape_sems["reshape"]   = .Reshape
	shape_sems["transpose"] = .Transpose
	shape_sems["sum"]       = .Reduction
	shape_sems["mean"]      = .Reduction

	vreg.modules["mimir.array"] = Virtual_Module{
		name             = "mimir.array",
		exports          = exports,
		shape_semantics  = shape_sems,
	}
}

// ==================== mimir.http ====================

register_mimir_http :: proc(vreg: ^Virtual_Registry, reg: ^Type_Registry) {
	exports := make(map[string]Type_ID, 16, reg.allocator)

	dict_str_str := make_dict_type(reg, TYPE_STR, TYPE_STR)
	dict_str_any := make_dict_type(reg, TYPE_STR, TYPE_ANY)

	// ---- Request class ----
	req_attrs := make(map[string]Type_ID, 12, reg.allocator)
	req_attrs["method"]       = TYPE_STR
	req_attrs["path"]         = TYPE_STR
	req_attrs["query_string"] = TYPE_STR
	req_attrs["headers"]      = dict_str_str
	req_attrs["cookies"]      = dict_str_str
	req_attrs["args"]         = dict_str_str
	req_attrs["form"]         = dict_str_str
	req_attrs["data"]         = TYPE_BYTES
	req_attrs["json"]         = make_callable_type(reg, {}, dict_str_any)
	req_attrs["text"]         = make_callable_type(reg, {}, TYPE_STR)

	request_class := register_type(reg, Class_Type{
		name  = "Request",
		attrs = req_attrs,
	})
	request_instance := make_instance_type(reg, request_class)
	exports["Request"] = request_class

	// ---- Response class ----
	// Register placeholder first, then update attrs in-place (methods return Response)
	resp_attrs := make(map[string]Type_ID, 10, reg.allocator)
	resp_attrs["status_code"] = TYPE_INT
	resp_attrs["body"]        = TYPE_BYTES
	resp_attrs["headers"]     = dict_str_str

	response_class := register_type(reg, Class_Type{
		name  = "Response",
		attrs = resp_attrs,
	})
	response_instance := make_instance_type(reg, response_class)
	exports["Response"] = response_class

	// Add methods that return Response — update the registered type in-place
	resp_type := get_type(reg, response_class)
	if resp_type != nil {
		if ct, ok := &resp_type.info.(Class_Type); ok {
			ct.attrs["json"] = make_callable_type(reg,
				{Param_Type{name = "data", type_id = dict_str_any}},
				response_instance,
			)
			ct.attrs["html"] = make_callable_type(reg,
				{Param_Type{name = "content", type_id = TYPE_STR}},
				response_instance,
			)
			ct.attrs["text"] = make_callable_type(reg,
				{Param_Type{name = "content", type_id = TYPE_STR}},
				response_instance,
			)
			ct.attrs["redirect"] = make_callable_type(reg,
				{
					Param_Type{name = "url", type_id = TYPE_STR},
					Param_Type{name = "status", type_id = TYPE_INT, has_default = true},
				},
				response_instance,
			)
		}
	}

	// ---- serve() ----
	exports["serve"] = make_callable_type(reg,
		{
			Param_Type{name = "port", type_id = TYPE_INT, has_default = true},
			Param_Type{name = "host", type_id = TYPE_STR, has_default = true},
		},
		TYPE_NONE,
	)

	// ---- route() decorator factory ----
	// route(method, path) -> Callable (decorator)
	// Returns a callable that takes a function and returns a function
	decorator_type := make_callable_type(reg,
		{Param_Type{name = "func", type_id = TYPE_ANY}},
		TYPE_ANY,
	)
	exports["route"] = make_callable_type(reg,
		{
			Param_Type{name = "method", type_id = TYPE_STR},
			Param_Type{name = "path",   type_id = TYPE_STR},
		},
		decorator_type,
	)

	// ---- websocket decorator ----
	exports["websocket"] = make_callable_type(reg,
		{Param_Type{name = "func", type_id = TYPE_ANY}},
		TYPE_ANY,
	)

	// ---- HTTP client functions ----
	// All return Response instances
	header_param := Param_Type{name = "headers", type_id = dict_str_str, has_default = true}
	timeout_param := Param_Type{name = "timeout", type_id = TYPE_FLOAT, has_default = true}

	exports["get"] = make_callable_type(reg,
		{
			Param_Type{name = "url", type_id = TYPE_STR},
			header_param,
			timeout_param,
		},
		response_instance,
	)

	body_params := []Param_Type{
		Param_Type{name = "url",     type_id = TYPE_STR},
		Param_Type{name = "json",    type_id = dict_str_any, has_default = true},
		Param_Type{name = "data",    type_id = TYPE_BYTES, has_default = true},
		header_param,
		timeout_param,
	}
	exports["post"]   = make_callable_type(reg, body_params, response_instance)
	exports["put"]    = make_callable_type(reg, body_params, response_instance)
	exports["delete"] = make_callable_type(reg,
		{
			Param_Type{name = "url", type_id = TYPE_STR},
			header_param,
			timeout_param,
		},
		response_instance,
	)
	exports["patch"] = make_callable_type(reg, body_params, response_instance)

	// Store Request/Response instance type IDs for route validation
	// (accessed via the registry's http_request_type / http_response_type)
	reg.http_request_type  = request_instance
	reg.http_response_type = response_instance

	vreg.modules["mimir.http"] = Virtual_Module{
		name    = "mimir.http",
		exports = exports,
	}
}
