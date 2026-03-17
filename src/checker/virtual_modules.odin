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

	// Register mimir.json
	register_mimir_json(&vreg, reg)

	// Register mimir.data
	register_mimir_data(&vreg, reg)

	// Register mimir.db
	register_mimir_db(&vreg, reg)

	// Register mimir.crypt
	register_mimir_crypt(&vreg, reg)

	// Register mimir.actor
	register_mimir_actor(&vreg, reg)

	// Register mimir.queue
	register_mimir_queue(&vreg, reg)

	// Register mimir.stats
	register_mimir_stats(&vreg, reg)

	// Register mimir.plot
	register_mimir_plot(&vreg, reg)

	// Register mimir.ml
	register_mimir_ml(&vreg, reg)

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
			// "import mimir.X" — create nested Module_Type so mimir.X.func works
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
			sub_name := local_name[dot_idx+1:] if dot_idx >= 0 else ""

			if sym_id, found := mod_scope.symbols[bound_name]; found {
				// Create Module_Type for the sub-module (mimir.X)
				child_module_id := register_type(reg, Module_Type{
					name    = imp.module_name,
					exports = vm.exports,
				})

				if dot_idx >= 0 && len(sub_name) > 0 {
					// Build nested: mimir → {X: Module_Type(mimir.X)}
					if existing_id, has_existing := result[sym_id]; has_existing {
						// Already have a parent Module_Type for "mimir" — add sub-module in-place
						existing_type := get_type(reg, existing_id)
						if existing_type != nil {
							#partial switch &mod in existing_type.info {
							case Module_Type:
								mod.exports[sub_name] = child_module_id
							}
						}
					} else {
						// First sub-module — create parent Module_Type
						parent_exports := make(map[string]Type_ID, 4, reg.allocator)
						parent_exports[sub_name] = child_module_id
						parent_id := register_type(reg, Module_Type{
							name    = bound_name,
							exports = parent_exports,
						})
						result[sym_id] = parent_id
					}
				} else {
					// No dot — single-level module name
					result[sym_id] = child_module_id
				}
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
	exports := make(map[string]Type_ID, 64, reg.allocator)

	// Tensor types for return values
	tensor_f64  := make_tensor_type(reg, TYPE_FLOAT, {})   // unknown shape
	tensor_int  := make_tensor_type(reg, TYPE_INT, {})
	tensor_bool := make_tensor_type(reg, TYPE_BOOL, {})

	// Common param patterns
	shape_param := Param_Type{name = "shape", type_id = TYPE_ANY, has_default = false}
	dtype_param := Param_Type{name = "dtype", type_id = TYPE_ANY, has_default = true}
	axis_param  := Param_Type{name = "axis",  type_id = TYPE_INT, has_default = true}
	a_param     := Param_Type{name = "a", type_id = tensor_f64}
	no_params   := make([]Param_Type, 0, reg.allocator)

	// ---- Creation ----
	exports["array"] = make_callable_type(reg,
		{Param_Type{name = "data", type_id = TYPE_ANY}},
		tensor_f64)
	exports["zeros"] = make_callable_type(reg, {shape_param, dtype_param}, tensor_f64)
	exports["ones"]  = make_callable_type(reg, {shape_param, dtype_param}, tensor_f64)
	exports["empty"] = make_callable_type(reg, {shape_param, dtype_param}, tensor_f64)
	exports["full"]  = make_callable_type(reg,
		{shape_param, Param_Type{name = "fill_value", type_id = TYPE_FLOAT}, dtype_param},
		tensor_f64)
	exports["eye"] = make_callable_type(reg,
		{Param_Type{name = "N", type_id = TYPE_INT}, Param_Type{name = "M", type_id = TYPE_INT, has_default = true}},
		tensor_f64)
	exports["arange"] = make_callable_type(reg,
		{
			Param_Type{name = "start", type_id = TYPE_INT},
			Param_Type{name = "stop",  type_id = TYPE_INT, has_default = true},
			Param_Type{name = "step",  type_id = TYPE_INT, has_default = true},
		},
		tensor_int)
	exports["linspace"] = make_callable_type(reg,
		{
			Param_Type{name = "start", type_id = TYPE_FLOAT},
			Param_Type{name = "stop",  type_id = TYPE_FLOAT},
			Param_Type{name = "num",   type_id = TYPE_INT, has_default = true},
		},
		tensor_f64)

	// ---- Arithmetic / operations ----
	exports["matmul"] = make_callable_type(reg,
		{a_param, Param_Type{name = "b", type_id = tensor_f64}},
		tensor_f64)
	exports["dot"] = make_callable_type(reg,
		{a_param, Param_Type{name = "b", type_id = tensor_f64}},
		tensor_f64)
	exports["cross"] = make_callable_type(reg,
		{a_param, Param_Type{name = "b", type_id = tensor_f64}},
		tensor_f64)

	// ---- Reductions ----
	exports["sum"]    = make_callable_type(reg, {a_param, axis_param}, tensor_f64)
	exports["mean"]   = make_callable_type(reg, {a_param, axis_param}, tensor_f64)
	exports["max"]    = make_callable_type(reg, {a_param, axis_param}, tensor_f64)
	exports["min"]    = make_callable_type(reg, {a_param, axis_param}, tensor_f64)
	exports["argmax"] = make_callable_type(reg, {a_param, axis_param}, tensor_int)
	exports["argmin"] = make_callable_type(reg, {a_param, axis_param}, tensor_int)
	exports["cumsum"] = make_callable_type(reg, {a_param, axis_param}, tensor_f64)

	// ---- Shape manipulation ----
	exports["reshape"]    = make_callable_type(reg, {a_param, Param_Type{name = "shape", type_id = TYPE_ANY}}, tensor_f64)
	exports["transpose"]  = make_callable_type(reg, {a_param}, tensor_f64)
	exports["flatten"]    = make_callable_type(reg, {a_param}, tensor_f64)
	exports["squeeze"]    = make_callable_type(reg, {a_param, axis_param}, tensor_f64)
	exports["expand_dims"] = make_callable_type(reg,
		{a_param, Param_Type{name = "axis", type_id = TYPE_INT}},
		tensor_f64)
	exports["concatenate"] = make_callable_type(reg,
		{Param_Type{name = "arrays", type_id = TYPE_ANY}, axis_param},
		tensor_f64)
	exports["stack"] = make_callable_type(reg,
		{Param_Type{name = "arrays", type_id = TYPE_ANY}, axis_param},
		tensor_f64)
	exports["split"] = make_callable_type(reg,
		{a_param, Param_Type{name = "indices_or_sections", type_id = TYPE_ANY}, axis_param},
		make_list_type(reg, tensor_f64))

	// ---- Linear algebra ----
	exports["solve"] = make_callable_type(reg,
		{a_param, Param_Type{name = "b", type_id = tensor_f64}},
		tensor_f64)
	exports["inv"]  = make_callable_type(reg, {a_param}, tensor_f64)
	exports["det"]  = make_callable_type(reg, {a_param}, TYPE_FLOAT)
	exports["norm"] = make_callable_type(reg,
		{a_param, Param_Type{name = "ord", type_id = TYPE_ANY, has_default = true}, axis_param},
		TYPE_FLOAT)
	exports["eig"] = make_callable_type(reg, {a_param},
		make_tuple_type(reg, {tensor_f64, tensor_f64}, false))
	exports["svd"] = make_callable_type(reg, {a_param},
		make_tuple_type(reg, {tensor_f64, tensor_f64, tensor_f64}, false))

	// ---- Comparison / logic ----
	exports["allclose"] = make_callable_type(reg,
		{a_param, Param_Type{name = "b", type_id = tensor_f64},
		 Param_Type{name = "rtol", type_id = TYPE_FLOAT, has_default = true},
		 Param_Type{name = "atol", type_id = TYPE_FLOAT, has_default = true}},
		TYPE_BOOL)
	exports["isnan"] = make_callable_type(reg, {a_param}, tensor_bool)
	exports["isinf"] = make_callable_type(reg, {a_param}, tensor_bool)
	exports["where"] = make_callable_type(reg,
		{Param_Type{name = "condition", type_id = tensor_bool},
		 Param_Type{name = "x", type_id = tensor_f64},
		 Param_Type{name = "y", type_id = tensor_f64}},
		tensor_f64)
	exports["clip"] = make_callable_type(reg,
		{a_param,
		 Param_Type{name = "a_min", type_id = TYPE_FLOAT, has_default = true},
		 Param_Type{name = "a_max", type_id = TYPE_FLOAT, has_default = true}},
		tensor_f64)
	exports["abs"] = make_callable_type(reg, {a_param}, tensor_f64)
	exports["sqrt"] = make_callable_type(reg, {a_param}, tensor_f64)
	exports["exp"] = make_callable_type(reg, {a_param}, tensor_f64)
	exports["log"] = make_callable_type(reg, {a_param}, tensor_f64)

	// ---- Random sub-module ----
	random_exports := make(map[string]Type_ID, 8, reg.allocator)
	random_exports["normal"] = make_callable_type(reg,
		{Param_Type{name = "loc", type_id = TYPE_FLOAT, has_default = true},
		 Param_Type{name = "scale", type_id = TYPE_FLOAT, has_default = true},
		 Param_Type{name = "size", type_id = TYPE_ANY, has_default = true}},
		tensor_f64)
	random_exports["uniform"] = make_callable_type(reg,
		{Param_Type{name = "low", type_id = TYPE_FLOAT, has_default = true},
		 Param_Type{name = "high", type_id = TYPE_FLOAT, has_default = true},
		 Param_Type{name = "size", type_id = TYPE_ANY, has_default = true}},
		tensor_f64)
	random_exports["randint"] = make_callable_type(reg,
		{Param_Type{name = "low", type_id = TYPE_INT},
		 Param_Type{name = "high", type_id = TYPE_INT, has_default = true},
		 Param_Type{name = "size", type_id = TYPE_ANY, has_default = true}},
		tensor_int)
	random_exports["seed"] = make_callable_type(reg,
		{Param_Type{name = "seed", type_id = TYPE_INT}},
		TYPE_NONE)
	random_exports["shuffle"] = make_callable_type(reg,
		{Param_Type{name = "x", type_id = tensor_f64}},
		TYPE_NONE)

	random_mod := register_type(reg, Module_Type{
		name    = "random",
		exports = random_exports,
	})
	exports["random"] = random_mod

	// ---- Shape semantics ----
	shape_sems := make(map[string]Shape_Semantic, 32, reg.allocator)
	shape_sems["zeros"]      = .Creation
	shape_sems["ones"]       = .Creation
	shape_sems["empty"]      = .Creation
	shape_sems["full"]       = .Creation
	shape_sems["eye"]        = .Creation
	shape_sems["array"]      = .Creation
	shape_sems["linspace"]   = .Creation
	shape_sems["arange"]     = .Arange
	shape_sems["matmul"]     = .Matmul
	shape_sems["dot"]        = .Matmul
	shape_sems["reshape"]    = .Reshape
	shape_sems["transpose"]  = .Transpose
	shape_sems["sum"]        = .Reduction
	shape_sems["mean"]       = .Reduction
	shape_sems["max"]        = .Reduction
	shape_sems["min"]        = .Reduction
	shape_sems["cumsum"]     = .Reduction

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
				{
					Param_Type{name = "data", type_id = dict_str_any},
					Param_Type{name = "status", type_id = TYPE_INT, has_default = true},
				},
				response_instance,
			)
			ct.attrs["html"] = make_callable_type(reg,
				{
					Param_Type{name = "content", type_id = TYPE_STR},
					Param_Type{name = "status", type_id = TYPE_INT, has_default = true},
				},
				response_instance,
			)
			ct.attrs["text"] = make_callable_type(reg,
				{
					Param_Type{name = "content", type_id = TYPE_STR},
					Param_Type{name = "status", type_id = TYPE_INT, has_default = true},
				},
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
		Param_Type{name = "url",       type_id = TYPE_STR},
		Param_Type{name = "json_data", type_id = dict_str_any, has_default = true},
		Param_Type{name = "data",      type_id = TYPE_BYTES, has_default = true},
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

// ==================== mimir.json ====================

register_mimir_json :: proc(vreg: ^Virtual_Registry, reg: ^Type_Registry) {
	exports := make(map[string]Type_ID, 16, reg.allocator)
	dict_str_any := make_dict_type(reg, TYPE_STR, TYPE_ANY)

	// Schema-aware: parse(data: str, schema: type) -> Any
	// Return type overridden in infer_call when schema resolves to TypedDict/class
	parse_type := make_callable_type(reg,
		{
			Param_Type{name = "data",   type_id = TYPE_STR},
			Param_Type{name = "schema", type_id = TYPE_ANY},
		},
		TYPE_ANY,
	)
	exports["parse"] = parse_type
	reg.json_parse_type = parse_type

	// read(path: str, schema: type) -> Any
	read_type := make_callable_type(reg,
		{
			Param_Type{name = "path",   type_id = TYPE_STR},
			Param_Type{name = "schema", type_id = TYPE_ANY},
		},
		TYPE_ANY,
	)
	exports["read"] = read_type
	reg.json_read_type = read_type

	// serialize(obj) -> str  (serializability checked post-inference)
	serialize_type := make_callable_type(reg,
		{Param_Type{name = "obj", type_id = TYPE_ANY}},
		TYPE_STR,
	)
	exports["serialize"] = serialize_type
	reg.json_serialize_type = serialize_type

	// write(obj, path: str) -> None
	write_type := make_callable_type(reg,
		{
			Param_Type{name = "obj",  type_id = TYPE_ANY},
			Param_Type{name = "path", type_id = TYPE_STR},
		},
		TYPE_NONE,
	)
	exports["write"] = write_type
	reg.json_write_type = write_type

	// Standard (untyped) operations — mirror stdlib json
	exports["load"] = make_callable_type(reg,
		{Param_Type{name = "path", type_id = TYPE_STR}},
		dict_str_any,
	)
	exports["loads"] = make_callable_type(reg,
		{Param_Type{name = "data", type_id = TYPE_STR}},
		dict_str_any,
	)

	dump_type := make_callable_type(reg,
		{
			Param_Type{name = "obj",  type_id = TYPE_ANY},
			Param_Type{name = "path", type_id = TYPE_STR},
		},
		TYPE_NONE,
	)
	exports["dump"] = dump_type
	reg.json_dump_type = dump_type

	dumps_type := make_callable_type(reg,
		{Param_Type{name = "obj", type_id = TYPE_ANY}},
		TYPE_STR,
	)
	exports["dumps"] = dumps_type
	reg.json_dumps_type = dumps_type

	vreg.modules["mimir.json"] = Virtual_Module{
		name    = "mimir.json",
		exports = exports,
	}
}

// ==================== mimir.data ====================

register_mimir_data :: proc(vreg: ^Virtual_Registry, reg: ^Type_Registry) {
	exports := make(map[string]Type_ID, 16, reg.allocator)

	// Unknown-column DataFrame as default return type
	empty_df := make_dataframe_type(reg, {})

	// read_csv(path: str, schema: type = Any) -> DataFrame
	read_csv_type := make_callable_type(reg,
		{
			Param_Type{name = "path",   type_id = TYPE_STR},
			Param_Type{name = "schema", type_id = TYPE_ANY, has_default = true},
		},
		empty_df,
	)
	exports["read_csv"] = read_csv_type
	reg.data_read_csv_type = read_csv_type

	// read_json(path: str, schema: type = Any) -> DataFrame
	read_json_type := make_callable_type(reg,
		{
			Param_Type{name = "path",   type_id = TYPE_STR},
			Param_Type{name = "schema", type_id = TYPE_ANY, has_default = true},
		},
		empty_df,
	)
	exports["read_json"] = read_json_type
	reg.data_read_json_type = read_json_type

	// read_parquet(path: str, schema: type = Any) -> DataFrame
	read_parquet_type := make_callable_type(reg,
		{
			Param_Type{name = "path",   type_id = TYPE_STR},
			Param_Type{name = "schema", type_id = TYPE_ANY, has_default = true},
		},
		empty_df,
	)
	exports["read_parquet"] = read_parquet_type
	reg.data_read_parquet_type = read_parquet_type

	// DataFrame(data: Any) -> DataFrame
	dataframe_type := make_callable_type(reg,
		{Param_Type{name = "data", type_id = TYPE_ANY, has_default = true}},
		empty_df,
	)
	exports["DataFrame"] = dataframe_type
	reg.data_dataframe_type = dataframe_type

	// Series(data: Any, name: str = "") -> Series
	exports["Series"] = make_callable_type(reg,
		{
			Param_Type{name = "data", type_id = TYPE_ANY},
			Param_Type{name = "name", type_id = TYPE_STR, has_default = true},
		},
		make_series_type(reg, TYPE_UNKNOWN),
	)

	// merge(left, right, on, how) -> DataFrame
	exports["merge"] = make_callable_type(reg,
		{
			Param_Type{name = "left",  type_id = empty_df},
			Param_Type{name = "right", type_id = empty_df},
			Param_Type{name = "on",    type_id = TYPE_STR, has_default = true},
			Param_Type{name = "how",   type_id = TYPE_STR, has_default = true},
		},
		empty_df,
	)

	// Register GroupBy class for method resolution
	gb_no_params := make([]Param_Type, 0, reg.allocator)
	gb_attrs := make(map[string]Type_ID, 8, reg.allocator)
	gb_attrs["sum"]   = make_callable_type(reg, gb_no_params, empty_df)
	gb_attrs["mean"]  = make_callable_type(reg, gb_no_params, empty_df)
	gb_attrs["min"]   = make_callable_type(reg, gb_no_params, empty_df)
	gb_attrs["max"]   = make_callable_type(reg, gb_no_params, empty_df)
	gb_attrs["count"] = make_callable_type(reg, gb_no_params, empty_df)
	gb_attrs["std"]   = make_callable_type(reg, gb_no_params, empty_df)
	reg.data_groupby_class = register_type(reg, Class_Type{
		name  = "GroupBy",
		attrs = gb_attrs,
	})

	vreg.modules["mimir.data"] = Virtual_Module{
		name    = "mimir.data",
		exports = exports,
	}
}

// ==================== mimir.db ====================

register_mimir_db :: proc(vreg: ^Virtual_Registry, reg: ^Type_Registry) {
	exports := make(map[string]Type_ID, 16, reg.allocator)

	dict_str_any := make_dict_type(reg, TYPE_STR, TYPE_ANY)
	list_dict := make_list_type(reg, dict_str_any)

	// ---- Connection class ----
	conn_attrs := make(map[string]Type_ID, 8, reg.allocator)
	conn_attrs["close"] = make_callable_type(reg, {}, TYPE_NONE)
	conn_attrs["in_transaction"] = TYPE_BOOL

	connection_class := register_type(reg, Class_Type{
		name  = "Connection",
		attrs = conn_attrs,
	})
	connection_instance := make_instance_type(reg, connection_class)
	exports["Connection"] = connection_class

	// ---- Transaction class ----
	tx_attrs := make(map[string]Type_ID, 4, reg.allocator)
	tx_attrs["commit"]   = make_callable_type(reg, {}, TYPE_NONE)
	tx_attrs["rollback"] = make_callable_type(reg, {}, TYPE_NONE)

	transaction_class := register_type(reg, Class_Type{
		name  = "Transaction",
		attrs = tx_attrs,
	})
	exports["Transaction"] = transaction_class

	// ---- connect(url: str) -> Connection ----
	exports["connect"] = make_callable_type(reg,
		{Param_Type{name = "url", type_id = TYPE_STR}},
		connection_instance,
	)

	// ---- query(conn, sql, params=[], result=Any) -> list[dict[str, Any]] ----
	query_type := make_callable_type(reg,
		{
			Param_Type{name = "conn",   type_id = connection_instance},
			Param_Type{name = "sql",    type_id = TYPE_STR},
			Param_Type{name = "params", type_id = make_list_type(reg, TYPE_ANY), has_default = true},
			Param_Type{name = "result", type_id = TYPE_ANY, has_default = true},
		},
		list_dict,
	)
	exports["query"] = query_type
	reg.db_query_type = query_type

	// ---- execute(conn, sql, params=[]) -> int ----
	execute_type := make_callable_type(reg,
		{
			Param_Type{name = "conn",   type_id = connection_instance},
			Param_Type{name = "sql",    type_id = TYPE_STR},
			Param_Type{name = "params", type_id = make_list_type(reg, TYPE_ANY), has_default = true},
		},
		TYPE_INT,
	)
	exports["execute"] = execute_type
	reg.db_execute_type = execute_type

	// ---- transaction(conn) -> Transaction ----
	transaction_instance := make_instance_type(reg, transaction_class)
	exports["transaction"] = make_callable_type(reg,
		{Param_Type{name = "conn", type_id = connection_instance}},
		transaction_instance,
	)

	// ---- Add query/execute methods to Connection (in-place update) ----
	conn_type := get_type(reg, connection_class)
	if conn_type != nil {
		if ct, ok := &conn_type.info.(Class_Type); ok {
			// Connection.query(sql, params=[], result=Any) -> list[dict[str, Any]]
			conn_query := make_callable_type(reg,
				{
					Param_Type{name = "sql",    type_id = TYPE_STR},
					Param_Type{name = "params", type_id = make_list_type(reg, TYPE_ANY), has_default = true},
					Param_Type{name = "result", type_id = TYPE_ANY, has_default = true},
				},
				list_dict,
			)
			ct.attrs["query"] = conn_query
			reg.db_conn_query_type = conn_query

			// Connection.execute(sql, params=[]) -> int
			conn_execute := make_callable_type(reg,
				{
					Param_Type{name = "sql",    type_id = TYPE_STR},
					Param_Type{name = "params", type_id = make_list_type(reg, TYPE_ANY), has_default = true},
				},
				TYPE_INT,
			)
			ct.attrs["execute"] = conn_execute
			reg.db_conn_execute_type = conn_execute
		}
	}

	vreg.modules["mimir.db"] = Virtual_Module{
		name    = "mimir.db",
		exports = exports,
	}
}

// ==================== mimir.crypt ====================

register_mimir_crypt :: proc(vreg: ^Virtual_Registry, reg: ^Type_Registry) {
	exports := make(map[string]Type_ID, 8, reg.allocator)

	// Helper: make a namespace (Instance_Type wrapping a Class_Type with method attrs)
	make_namespace :: proc(reg: ^Type_Registry, name: string, attrs: map[string]Type_ID) -> Type_ID {
		class_id := register_type(reg, Class_Type{
			name  = name,
			attrs = attrs,
		})
		return make_instance_type(reg, class_id)
	}

	// ---- hash namespace ----
	hash_attrs := make(map[string]Type_ID, 8, reg.allocator)
	hash_attrs["bcrypt"]   = make_callable_type(reg, {Param_Type{name = "password", type_id = TYPE_STR}}, TYPE_STR)
	hash_attrs["argon2"]   = make_callable_type(reg, {Param_Type{name = "password", type_id = TYPE_STR}}, TYPE_STR)
	hash_attrs["sha256"]   = make_callable_type(reg, {Param_Type{name = "data", type_id = TYPE_BYTES}}, TYPE_STR)
	hash_attrs["sha512"]   = make_callable_type(reg, {Param_Type{name = "data", type_id = TYPE_BYTES}}, TYPE_STR)
	hash_attrs["sha3_256"] = make_callable_type(reg, {Param_Type{name = "data", type_id = TYPE_BYTES}}, TYPE_STR)
	hash_attrs["md5"]      = make_callable_type(reg, {Param_Type{name = "data", type_id = TYPE_BYTES}}, TYPE_STR)
	hash_attrs["sha1"]     = make_callable_type(reg, {Param_Type{name = "data", type_id = TYPE_BYTES}}, TYPE_STR)
	exports["hash"] = make_namespace(reg, "hash", hash_attrs)

	// ---- verify namespace ----
	verify_attrs := make(map[string]Type_ID, 4, reg.allocator)
	verify_params := []Param_Type{
		{name = "password", type_id = TYPE_STR},
		{name = "hashed",   type_id = TYPE_STR},
	}
	verify_attrs["bcrypt"] = make_callable_type(reg, verify_params, TYPE_BOOL)
	verify_attrs["argon2"] = make_callable_type(reg, verify_params, TYPE_BOOL)
	exports["verify"] = make_namespace(reg, "verify", verify_attrs)

	// ---- encrypt namespace ----
	encrypt_attrs := make(map[string]Type_ID, 8, reg.allocator)
	enc_params := []Param_Type{
		{name = "key",       type_id = TYPE_BYTES},
		{name = "plaintext", type_id = TYPE_BYTES},
	}
	encrypt_attrs["aes_gcm"]  = make_callable_type(reg, enc_params, TYPE_BYTES)
	encrypt_attrs["aes_cbc"]  = make_callable_type(reg, enc_params, TYPE_BYTES)
	encrypt_attrs["aes_ctr"]  = make_callable_type(reg, enc_params, TYPE_BYTES)
	encrypt_attrs["aes_ecb"]  = make_callable_type(reg, enc_params, TYPE_BYTES)
	encrypt_attrs["chacha20"] = make_callable_type(reg, enc_params, TYPE_BYTES)
	exports["encrypt"] = make_namespace(reg, "encrypt", encrypt_attrs)

	// ---- decrypt namespace ----
	decrypt_attrs := make(map[string]Type_ID, 8, reg.allocator)
	dec_params := []Param_Type{
		{name = "key",        type_id = TYPE_BYTES},
		{name = "ciphertext", type_id = TYPE_BYTES},
	}
	decrypt_attrs["aes_gcm"]  = make_callable_type(reg, dec_params, TYPE_BYTES)
	decrypt_attrs["aes_cbc"]  = make_callable_type(reg, dec_params, TYPE_BYTES)
	decrypt_attrs["aes_ctr"]  = make_callable_type(reg, dec_params, TYPE_BYTES)
	decrypt_attrs["aes_ecb"]  = make_callable_type(reg, dec_params, TYPE_BYTES)
	decrypt_attrs["chacha20"] = make_callable_type(reg, dec_params, TYPE_BYTES)
	exports["decrypt"] = make_namespace(reg, "decrypt", decrypt_attrs)

	// ---- token namespace ----
	token_attrs := make(map[string]Type_ID, 4, reg.allocator)
	n_param := []Param_Type{{name = "n", type_id = TYPE_INT}}
	token_attrs["bytes"]   = make_callable_type(reg, n_param, TYPE_BYTES)
	token_attrs["urlsafe"] = make_callable_type(reg, n_param, TYPE_STR)
	token_attrs["digits"]  = make_callable_type(reg, n_param, TYPE_STR)
	token_attrs["hex"]     = make_callable_type(reg, n_param, TYPE_STR)
	exports["token"] = make_namespace(reg, "token", token_attrs)

	// ---- sign namespace ----
	sign_attrs := make(map[string]Type_ID, 4, reg.allocator)
	sign_params := []Param_Type{
		{name = "key",     type_id = TYPE_BYTES},
		{name = "message", type_id = TYPE_BYTES},
	}
	sign_attrs["hmac_sha256"] = make_callable_type(reg, sign_params, TYPE_BYTES)
	sign_attrs["hmac_sha512"] = make_callable_type(reg, sign_params, TYPE_BYTES)
	sign_attrs["ed25519"]     = make_callable_type(reg, sign_params, TYPE_BYTES)
	exports["sign"] = make_namespace(reg, "sign", sign_attrs)

	vreg.modules["mimir.crypt"] = Virtual_Module{
		name    = "mimir.crypt",
		exports = exports,
	}
}

// ==================== mimir.actor ====================

register_mimir_actor :: proc(vreg: ^Virtual_Registry, reg: ^Type_Registry) {
	exports := make(map[string]Type_ID, 8, reg.allocator)

	// ---- Actor base class ----
	actor_attrs := make(map[string]Type_ID, 4, reg.allocator)
	actor_attrs["on_receive"] = make_callable_type(reg,
		{Param_Type{name = "message", type_id = TYPE_ANY}},
		TYPE_ANY,
	)
	actor_attrs["pre_start"] = make_callable_type(reg, {}, TYPE_NONE)
	actor_attrs["post_stop"] = make_callable_type(reg, {}, TYPE_NONE)

	actor_class := register_type(reg, Class_Type{
		name  = "Actor",
		attrs = actor_attrs,
	})
	exports["Actor"] = actor_class

	// ---- ActorRef class ----
	actor_ref_attrs := make(map[string]Type_ID, 4, reg.allocator)
	actor_ref_attrs["send"] = make_callable_type(reg,
		{Param_Type{name = "message", type_id = TYPE_ANY}},
		TYPE_NONE,
	)
	actor_ref_attrs["ask"] = make_callable_type(reg,
		{
			Param_Type{name = "message", type_id = TYPE_ANY},
			Param_Type{name = "timeout", type_id = TYPE_FLOAT, has_default = true},
		},
		TYPE_ANY,
	)
	actor_ref_attrs["stop"] = make_callable_type(reg, {}, TYPE_NONE)
	actor_ref_attrs["is_alive"] = make_callable_type(reg, {}, TYPE_BOOL)

	actor_ref_class := register_type(reg, Class_Type{
		name  = "ActorRef",
		attrs = actor_ref_attrs,
	})
	actor_ref_instance := make_instance_type(reg, actor_ref_class)
	exports["ActorRef"] = actor_ref_class

	// ---- ActorSystem class ----
	system_attrs := make(map[string]Type_ID, 4, reg.allocator)
	system_spawn_type := make_callable_type(reg,
		{Param_Type{name = "actor_class", type_id = TYPE_ANY}},
		actor_ref_instance,
	)
	system_attrs["spawn"] = system_spawn_type
	reg.actor_system_spawn_type = system_spawn_type
	system_attrs["supervise"] = make_callable_type(reg,
		{
			Param_Type{name = "ref",          type_id = TYPE_ANY},
			Param_Type{name = "strategy",     type_id = TYPE_STR, has_default = true},
			Param_Type{name = "max_restarts", type_id = TYPE_INT, has_default = true},
			Param_Type{name = "within",       type_id = TYPE_FLOAT, has_default = true},
		},
		TYPE_NONE,
	)
	system_attrs["shutdown"] = make_callable_type(reg,
		{Param_Type{name = "timeout", type_id = TYPE_FLOAT, has_default = true}},
		TYPE_NONE,
	)
	system_attrs["actors"] = make_list_type(reg, actor_ref_instance)

	system_class := register_type(reg, Class_Type{
		name  = "ActorSystem",
		attrs = system_attrs,
	})
	exports["ActorSystem"] = system_class

	// ---- spawn() convenience function ----
	spawn_type := make_callable_type(reg,
		{Param_Type{name = "actor_class", type_id = TYPE_ANY}},
		actor_ref_instance,
	)
	exports["spawn"] = spawn_type
	reg.actor_spawn_type = spawn_type
	reg.actor_ref_class = actor_ref_class

	vreg.modules["mimir.actor"] = Virtual_Module{
		name    = "mimir.actor",
		exports = exports,
	}
}

// ==================== mimir.queue ====================

register_mimir_queue :: proc(vreg: ^Virtual_Registry, reg: ^Type_Registry) {
	exports := make(map[string]Type_ID, 4, reg.allocator)

	// ---- Job class ----
	job_attrs := make(map[string]Type_ID, 4, reg.allocator)
	job_attrs["status"] = TYPE_STR
	job_attrs["id"] = TYPE_STR
	job_attrs["result"] = make_callable_type(reg,
		{Param_Type{name = "timeout", type_id = TYPE_FLOAT, has_default = true}},
		TYPE_ANY,
	)
	job_attrs["cancel"] = make_callable_type(reg, {}, TYPE_NONE)

	job_class := register_type(reg, Class_Type{
		name  = "Job",
		attrs = job_attrs,
	})
	job_instance := make_instance_type(reg, job_class)
	exports["Job"] = job_class

	// ---- Queue class ----
	queue_attrs := make(map[string]Type_ID, 8, reg.allocator)
	queue_attrs["submit"] = make_callable_type(reg,
		{Param_Type{name = "func", type_id = TYPE_ANY}},
		job_instance,
	)
	queue_attrs["start"] = make_callable_type(reg, {}, TYPE_NONE)
	queue_attrs["shutdown"] = make_callable_type(reg,
		{Param_Type{name = "timeout", type_id = TYPE_FLOAT, has_default = true}},
		TYPE_NONE,
	)
	queue_attrs["pending"] = TYPE_INT

	queue_class := register_type(reg, Class_Type{
		name  = "Queue",
		attrs = queue_attrs,
	})
	exports["Queue"] = queue_class

	// ---- task decorator ----
	// task(func) -> func (decorator preserves callable, adds .delay at runtime)
	exports["task"] = make_callable_type(reg,
		{Param_Type{name = "func", type_id = TYPE_ANY}},
		TYPE_ANY,
	)

	vreg.modules["mimir.queue"] = Virtual_Module{
		name    = "mimir.queue",
		exports = exports,
	}
}

// ==================== mimir.stats ====================

register_mimir_stats :: proc(vreg: ^Virtual_Registry, reg: ^Type_Registry) {
	exports := make(map[string]Type_ID, 64, reg.allocator)

	tensor_f64 := make_tensor_type(reg, TYPE_FLOAT, {})
	no_params  := make([]Param_Type, 0, reg.allocator)

	// ---- Distribution method attrs (continuous vs discrete) ----
	sample_method := make_callable_type(reg,
		{Param_Type{name = "size", type_id = TYPE_INT, has_default = true}},
		tensor_f64)
	cdf_method := make_callable_type(reg,
		{Param_Type{name = "x", type_id = TYPE_FLOAT}},
		TYPE_FLOAT)
	ppf_method := make_callable_type(reg,
		{Param_Type{name = "q", type_id = TYPE_FLOAT}},
		TYPE_FLOAT)
	mean_method := make_callable_type(reg, no_params, TYPE_FLOAT)
	std_method  := make_callable_type(reg, no_params, TYPE_FLOAT)
	var_method  := make_callable_type(reg, no_params, TYPE_FLOAT)

	// Continuous: has pdf, no pmf
	cont_attrs := make(map[string]Type_ID, 8, reg.allocator)
	cont_attrs["sample"] = sample_method
	cont_attrs["pdf"]    = make_callable_type(reg, {Param_Type{name = "x", type_id = TYPE_FLOAT}}, TYPE_FLOAT)
	cont_attrs["cdf"]    = cdf_method
	cont_attrs["ppf"]    = ppf_method
	cont_attrs["mean"]   = mean_method
	cont_attrs["std"]    = std_method
	cont_attrs["var"]    = var_method

	// Discrete: has pmf, no pdf
	disc_attrs := make(map[string]Type_ID, 8, reg.allocator)
	disc_attrs["sample"] = sample_method
	disc_attrs["pmf"]    = make_callable_type(reg, {Param_Type{name = "x", type_id = TYPE_INT}}, TYPE_FLOAT)
	disc_attrs["cdf"]    = cdf_method
	disc_attrs["ppf"]    = ppf_method
	disc_attrs["mean"]   = mean_method
	disc_attrs["std"]    = std_method
	disc_attrs["var"]    = var_method

	// Helper: register a distribution class with given constructor params
	_register_dist :: proc(
		reg: ^Type_Registry, exports: ^map[string]Type_ID,
		name: string, params: []Param_Type, attrs: map[string]Type_ID,
	) {
		class_id := register_type(reg, Class_Type{
			name  = name,
			attrs = attrs,
		})
		inst_id := make_instance_type(reg, class_id)
		exports[name] = make_callable_type(reg, params, inst_id)
	}

	// ---- Continuous distributions ----
	_register_dist(reg, &exports, "Normal", {
		Param_Type{name = "mean", type_id = TYPE_FLOAT, has_default = true},
		Param_Type{name = "std",  type_id = TYPE_FLOAT, has_default = true},
	}, cont_attrs)
	_register_dist(reg, &exports, "Uniform", {
		Param_Type{name = "low",  type_id = TYPE_FLOAT, has_default = true},
		Param_Type{name = "high", type_id = TYPE_FLOAT, has_default = true},
	}, cont_attrs)
	_register_dist(reg, &exports, "Exponential", {
		Param_Type{name = "rate", type_id = TYPE_FLOAT, has_default = true},
	}, cont_attrs)
	_register_dist(reg, &exports, "Beta", {
		Param_Type{name = "a", type_id = TYPE_FLOAT, has_default = true},
		Param_Type{name = "b", type_id = TYPE_FLOAT, has_default = true},
	}, cont_attrs)
	_register_dist(reg, &exports, "Gamma", {
		Param_Type{name = "shape", type_id = TYPE_FLOAT, has_default = true},
		Param_Type{name = "scale", type_id = TYPE_FLOAT, has_default = true},
	}, cont_attrs)
	_register_dist(reg, &exports, "StudentT", {
		Param_Type{name = "df", type_id = TYPE_FLOAT, has_default = true},
	}, cont_attrs)
	_register_dist(reg, &exports, "Chi2", {
		Param_Type{name = "df", type_id = TYPE_FLOAT, has_default = true},
	}, cont_attrs)
	_register_dist(reg, &exports, "F", {
		Param_Type{name = "dfn", type_id = TYPE_FLOAT, has_default = true},
		Param_Type{name = "dfd", type_id = TYPE_FLOAT, has_default = true},
	}, cont_attrs)

	// ---- Discrete distributions ----
	_register_dist(reg, &exports, "Binomial", {
		Param_Type{name = "n", type_id = TYPE_INT, has_default = true},
		Param_Type{name = "p", type_id = TYPE_FLOAT, has_default = true},
	}, disc_attrs)
	_register_dist(reg, &exports, "Poisson", {
		Param_Type{name = "lam", type_id = TYPE_FLOAT, has_default = true},
	}, disc_attrs)
	_register_dist(reg, &exports, "Geometric", {
		Param_Type{name = "p", type_id = TYPE_FLOAT, has_default = true},
	}, disc_attrs)
	_register_dist(reg, &exports, "Bernoulli", {
		Param_Type{name = "p", type_id = TYPE_FLOAT, has_default = true},
	}, disc_attrs)

	// ---- Result types ----
	test_result_attrs := make(map[string]Type_ID, 4, reg.allocator)
	test_result_attrs["statistic"] = TYPE_FLOAT
	test_result_attrs["p_value"]   = TYPE_FLOAT
	test_result_attrs["df"]        = TYPE_FLOAT
	test_result_class := register_type(reg, Class_Type{
		name  = "TestResult",
		attrs = test_result_attrs,
	})
	test_result := make_instance_type(reg, test_result_class)

	corr_result_attrs := make(map[string]Type_ID, 3, reg.allocator)
	corr_result_attrs["r"]       = TYPE_FLOAT
	corr_result_attrs["p_value"] = TYPE_FLOAT
	corr_result_class := register_type(reg, Class_Type{
		name  = "CorrelationResult",
		attrs = corr_result_attrs,
	})
	corr_result := make_instance_type(reg, corr_result_class)

	reg_result_attrs := make(map[string]Type_ID, 5, reg.allocator)
	reg_result_attrs["coefficients"] = tensor_f64
	reg_result_attrs["intercept"]    = TYPE_FLOAT
	reg_result_attrs["r_squared"]    = TYPE_FLOAT
	reg_result_attrs["p_values"]     = tensor_f64
	reg_result_attrs["accuracy"]     = TYPE_FLOAT
	reg_result_class := register_type(reg, Class_Type{
		name  = "RegressionResult",
		attrs = reg_result_attrs,
	})
	reg_result := make_instance_type(reg, reg_result_class)

	// ---- Hypothesis tests ----
	tensor_param := Param_Type{name = "a", type_id = tensor_f64}
	tensor_param_b := Param_Type{name = "b", type_id = tensor_f64}

	exports["ttest"] = make_callable_type(reg, {tensor_param, tensor_param_b}, test_result)
	exports["chi2_test"] = make_callable_type(reg,
		{Param_Type{name = "observed", type_id = tensor_f64},
		 Param_Type{name = "expected", type_id = tensor_f64, has_default = true}},
		test_result)
	exports["anova"] = make_callable_type(reg,
		{Param_Type{name = "groups", type_id = TYPE_ANY}},  // *args
		test_result)
	exports["mann_whitney"] = make_callable_type(reg, {tensor_param, tensor_param_b}, test_result)
	exports["ks_test"] = make_callable_type(reg, {tensor_param, tensor_param_b}, test_result)

	// ---- Correlation ----
	x_param := Param_Type{name = "x", type_id = tensor_f64}
	y_param := Param_Type{name = "y", type_id = tensor_f64}

	exports["pearson"]  = make_callable_type(reg, {x_param, y_param}, corr_result)
	exports["spearman"] = make_callable_type(reg, {x_param, y_param}, corr_result)
	exports["kendall"]  = make_callable_type(reg, {x_param, y_param}, corr_result)

	// ---- Regression ----
	X_param := Param_Type{name = "X", type_id = tensor_f64}

	exports["linear_regression"]   = make_callable_type(reg, {X_param, y_param}, reg_result)
	exports["logistic_regression"] = make_callable_type(reg, {X_param, y_param}, reg_result)

	// ---- Descriptive statistics ----
	a_param := Param_Type{name = "a", type_id = tensor_f64}

	exports["median"]     = make_callable_type(reg, {a_param}, TYPE_FLOAT)
	exports["mode"]       = make_callable_type(reg, {a_param}, TYPE_FLOAT)
	exports["skew"]       = make_callable_type(reg, {a_param}, TYPE_FLOAT)
	exports["kurtosis"]   = make_callable_type(reg, {a_param}, TYPE_FLOAT)
	exports["percentile"] = make_callable_type(reg,
		{a_param, Param_Type{name = "q", type_id = TYPE_FLOAT}},
		TYPE_FLOAT)

	vreg.modules["mimir.stats"] = Virtual_Module{
		name    = "mimir.stats",
		exports = exports,
	}
}

// ==================== mimir.plot ====================

register_mimir_plot :: proc(vreg: ^Virtual_Registry, reg: ^Type_Registry) {
	exports := make(map[string]Type_ID, 32, reg.allocator)

	tensor_f64 := make_tensor_type(reg, TYPE_FLOAT, {})
	no_params  := make([]Param_Type, 0, reg.allocator)

	// Common params across chart types
	title_param   := Param_Type{name = "title",  type_id = TYPE_STR, has_default = true}
	xlabel_param  := Param_Type{name = "xlabel", type_id = TYPE_STR, has_default = true}
	ylabel_param  := Param_Type{name = "ylabel", type_id = TYPE_STR, has_default = true}
	color_param   := Param_Type{name = "color",  type_id = TYPE_STR, has_default = true}
	label_param   := Param_Type{name = "label",  type_id = TYPE_STR, has_default = true}

	// ---- Figure class (returned by chart functions for chaining) ----
	fig_attrs := make(map[string]Type_ID, 8, reg.allocator)
	fig_attrs["title"]  = make_callable_type(reg, {Param_Type{name = "text", type_id = TYPE_STR}}, TYPE_NONE)
	fig_attrs["xlabel"] = make_callable_type(reg, {Param_Type{name = "text", type_id = TYPE_STR}}, TYPE_NONE)
	fig_attrs["ylabel"] = make_callable_type(reg, {Param_Type{name = "text", type_id = TYPE_STR}}, TYPE_NONE)
	fig_attrs["legend"] = make_callable_type(reg, no_params, TYPE_NONE)
	fig_attrs["grid"]   = make_callable_type(reg,
		{Param_Type{name = "visible", type_id = TYPE_BOOL, has_default = true}},
		TYPE_NONE)
	fig_attrs["show"]   = make_callable_type(reg, no_params, TYPE_NONE)
	fig_attrs["save"]   = make_callable_type(reg,
		{Param_Type{name = "path", type_id = TYPE_STR}},
		TYPE_NONE)

	fig_class := register_type(reg, Class_Type{
		name  = "Figure",
		attrs = fig_attrs,
	})
	fig_type := make_instance_type(reg, fig_class)

	// ---- Chart functions ----
	// Each accepts data (arrays or DataFrame) + styling params, returns Figure

	// plot(x, y, ...) — line chart
	exports["plot"] = make_callable_type(reg,
		{Param_Type{name = "x", type_id = TYPE_ANY},
		 Param_Type{name = "y", type_id = TYPE_ANY, has_default = true},
		 title_param, xlabel_param, ylabel_param, color_param, label_param},
		fig_type)

	// scatter(x, y, ...) — scatter plot
	exports["scatter"] = make_callable_type(reg,
		{Param_Type{name = "x", type_id = TYPE_ANY},
		 Param_Type{name = "y", type_id = TYPE_ANY},
		 title_param, xlabel_param, ylabel_param, color_param,
		 Param_Type{name = "size", type_id = TYPE_ANY, has_default = true}},
		fig_type)

	// bar(data, x, y, ...) — bar chart (DataFrame-aware)
	exports["bar"] = make_callable_type(reg,
		{Param_Type{name = "data", type_id = TYPE_ANY},
		 Param_Type{name = "x", type_id = TYPE_STR},
		 Param_Type{name = "y", type_id = TYPE_STR},
		 title_param, color_param},
		fig_type)

	// hist(data, ...) — histogram
	exports["hist"] = make_callable_type(reg,
		{Param_Type{name = "data", type_id = TYPE_ANY},
		 Param_Type{name = "bins", type_id = TYPE_INT, has_default = true},
		 title_param, xlabel_param, ylabel_param, color_param},
		fig_type)

	// box(data, ...) — box plot
	exports["box"] = make_callable_type(reg,
		{Param_Type{name = "data", type_id = TYPE_ANY},
		 title_param, xlabel_param, ylabel_param},
		fig_type)

	// violin(data, ...) — violin plot
	exports["violin"] = make_callable_type(reg,
		{Param_Type{name = "data", type_id = TYPE_ANY},
		 title_param, xlabel_param, ylabel_param},
		fig_type)

	// heatmap(data, ...) — heatmap
	exports["heatmap"] = make_callable_type(reg,
		{Param_Type{name = "data", type_id = TYPE_ANY},
		 title_param,
		 Param_Type{name = "cmap", type_id = TYPE_STR, has_default = true},
		 Param_Type{name = "annot", type_id = TYPE_BOOL, has_default = true}},
		fig_type)

	// pie(values, labels, ...) — pie chart
	exports["pie"] = make_callable_type(reg,
		{Param_Type{name = "values", type_id = TYPE_ANY},
		 Param_Type{name = "labels", type_id = TYPE_ANY, has_default = true},
		 title_param},
		fig_type)

	// ---- Utility functions ----
	// save(path) — save current figure
	exports["save"] = make_callable_type(reg,
		{Param_Type{name = "path", type_id = TYPE_STR}},
		TYPE_NONE)

	// show() — display current figure
	exports["show"] = make_callable_type(reg, no_params, TYPE_NONE)

	// figure(width, height) — create new figure
	exports["figure"] = make_callable_type(reg,
		{Param_Type{name = "width", type_id = TYPE_INT, has_default = true},
		 Param_Type{name = "height", type_id = TYPE_INT, has_default = true}},
		fig_type)

	// subplot(rows, cols, index) — create subplot
	exports["subplot"] = make_callable_type(reg,
		{Param_Type{name = "rows", type_id = TYPE_INT},
		 Param_Type{name = "cols", type_id = TYPE_INT},
		 Param_Type{name = "index", type_id = TYPE_INT}},
		fig_type)

	// subplots(rows, cols) → (Figure, list[Figure])
	exports["subplots"] = make_callable_type(reg,
		{Param_Type{name = "rows", type_id = TYPE_INT, has_default = true},
		 Param_Type{name = "cols", type_id = TYPE_INT, has_default = true}},
		make_tuple_type(reg, {fig_type, make_list_type(reg, fig_type)}, false))

	vreg.modules["mimir.plot"] = Virtual_Module{
		name    = "mimir.plot",
		exports = exports,
	}
}

// ==================== mimir.ml ====================

register_mimir_ml :: proc(vreg: ^Virtual_Registry, reg: ^Type_Registry) {
	exports := make(map[string]Type_ID, 64, reg.allocator)

	tensor_f64 := make_tensor_type(reg, TYPE_FLOAT, {})
	no_params  := make([]Param_Type, 0, reg.allocator)

	// ---- Module base class ----
	module_attrs := make(map[string]Type_ID, 8, reg.allocator)
	module_attrs["forward"]    = make_callable_type(reg,
		{Param_Type{name = "x", type_id = tensor_f64}}, tensor_f64)
	module_attrs["parameters"] = make_callable_type(reg, no_params,
		make_list_type(reg, tensor_f64))
	module_attrs["train"]      = make_callable_type(reg, no_params, TYPE_NONE)
	module_attrs["eval"]       = make_callable_type(reg, no_params, TYPE_NONE)
	module_attrs["state_dict"] = make_callable_type(reg, no_params,
		make_dict_type(reg, TYPE_STR, tensor_f64))
	module_attrs["load_state_dict"] = make_callable_type(reg,
		{Param_Type{name = "state", type_id = make_dict_type(reg, TYPE_STR, tensor_f64)}},
		TYPE_NONE)

	module_class := register_type(reg, Class_Type{
		name  = "Module",
		attrs = module_attrs,
	})
	module_inst := make_instance_type(reg, module_class)
	exports["Module"] = make_callable_type(reg, no_params, module_inst)

	// ---- Layer classes ----
	// Helper: register a layer class that is callable (Tensor → Tensor) + has Module methods
	_register_layer :: proc(
		reg: ^Type_Registry, exports: ^map[string]Type_ID,
		name: string, params: []Param_Type,
		module_attrs: map[string]Type_ID, tensor_type: Type_ID,
	) {
		layer_attrs := make(map[string]Type_ID, len(module_attrs) + 2, reg.allocator)
		for k, v in module_attrs { layer_attrs[k] = v }
		layer_attrs["__call__"] = make_callable_type(reg,
			{Param_Type{name = "x", type_id = tensor_type}}, tensor_type)

		class_id := register_type(reg, Class_Type{
			name  = name,
			attrs = layer_attrs,
		})
		inst_id := make_instance_type(reg, class_id)
		exports[name] = make_callable_type(reg, params, inst_id)
	}

	// Linear(in_features, out_features, bias=True)
	_register_layer(reg, &exports, "Linear", {
		Param_Type{name = "in_features",  type_id = TYPE_INT},
		Param_Type{name = "out_features", type_id = TYPE_INT},
		Param_Type{name = "bias", type_id = TYPE_BOOL, has_default = true},
	}, module_attrs, tensor_f64)

	// Conv2d(in_channels, out_channels, kernel_size, stride=1, padding=0)
	_register_layer(reg, &exports, "Conv2d", {
		Param_Type{name = "in_channels",  type_id = TYPE_INT},
		Param_Type{name = "out_channels", type_id = TYPE_INT},
		Param_Type{name = "kernel_size",  type_id = TYPE_INT},
		Param_Type{name = "stride",  type_id = TYPE_INT, has_default = true},
		Param_Type{name = "padding", type_id = TYPE_INT, has_default = true},
	}, module_attrs, tensor_f64)

	// LayerNorm(normalized_shape)
	_register_layer(reg, &exports, "LayerNorm", {
		Param_Type{name = "normalized_shape", type_id = TYPE_INT},
	}, module_attrs, tensor_f64)

	// BatchNorm(num_features)
	_register_layer(reg, &exports, "BatchNorm", {
		Param_Type{name = "num_features", type_id = TYPE_INT},
	}, module_attrs, tensor_f64)

	// Dropout(p=0.5)
	_register_layer(reg, &exports, "Dropout", {
		Param_Type{name = "p", type_id = TYPE_FLOAT, has_default = true},
	}, module_attrs, tensor_f64)

	// Embedding(num_embeddings, embedding_dim)
	_register_layer(reg, &exports, "Embedding", {
		Param_Type{name = "num_embeddings", type_id = TYPE_INT},
		Param_Type{name = "embedding_dim",  type_id = TYPE_INT},
	}, module_attrs, tensor_f64)

	// ---- Activation functions (Tensor → Tensor) ----
	act_type := make_callable_type(reg,
		{Param_Type{name = "x", type_id = tensor_f64}}, tensor_f64)
	exports["relu"]       = act_type
	exports["gelu"]       = act_type
	exports["silu"]       = act_type
	exports["sigmoid"]    = act_type
	exports["tanh"]       = act_type
	exports["softmax"]    = make_callable_type(reg,
		{Param_Type{name = "x", type_id = tensor_f64},
		 Param_Type{name = "dim", type_id = TYPE_INT, has_default = true}},
		tensor_f64)
	exports["log_softmax"] = make_callable_type(reg,
		{Param_Type{name = "x", type_id = tensor_f64},
		 Param_Type{name = "dim", type_id = TYPE_INT, has_default = true}},
		tensor_f64)

	// ---- Loss functions ((Tensor, Tensor) → Tensor) ----
	loss_type := make_callable_type(reg,
		{Param_Type{name = "input",  type_id = tensor_f64},
		 Param_Type{name = "target", type_id = tensor_f64}},
		tensor_f64)
	exports["cross_entropy"]        = loss_type
	exports["mse_loss"]             = loss_type
	exports["binary_cross_entropy"] = loss_type

	// ---- Optimizer classes ----
	opt_attrs := make(map[string]Type_ID, 4, reg.allocator)
	opt_attrs["step"]      = make_callable_type(reg, no_params, TYPE_NONE)
	opt_attrs["zero_grad"] = make_callable_type(reg, no_params, TYPE_NONE)

	params_param := Param_Type{name = "params", type_id = TYPE_ANY}
	lr_param     := Param_Type{name = "lr", type_id = TYPE_FLOAT}

	// SGD(params, lr, momentum=0)
	sgd_class := register_type(reg, Class_Type{name = "SGD", attrs = opt_attrs})
	sgd_inst  := make_instance_type(reg, sgd_class)
	exports["SGD"] = make_callable_type(reg, {
		params_param, lr_param,
		Param_Type{name = "momentum", type_id = TYPE_FLOAT, has_default = true},
	}, sgd_inst)

	// Adam(params, lr=1e-3, betas=(0.9,0.999), eps=1e-8)
	adam_class := register_type(reg, Class_Type{name = "Adam", attrs = opt_attrs})
	adam_inst  := make_instance_type(reg, adam_class)
	exports["Adam"] = make_callable_type(reg, {
		params_param,
		Param_Type{name = "lr",   type_id = TYPE_FLOAT, has_default = true},
		Param_Type{name = "betas", type_id = TYPE_ANY, has_default = true},
		Param_Type{name = "eps",  type_id = TYPE_FLOAT, has_default = true},
	}, adam_inst)

	// AdamW(params, lr=1e-3, weight_decay=0.01)
	adamw_class := register_type(reg, Class_Type{name = "AdamW", attrs = opt_attrs})
	adamw_inst  := make_instance_type(reg, adamw_class)
	exports["AdamW"] = make_callable_type(reg, {
		params_param,
		Param_Type{name = "lr",           type_id = TYPE_FLOAT, has_default = true},
		Param_Type{name = "weight_decay", type_id = TYPE_FLOAT, has_default = true},
	}, adamw_inst)

	// ---- Tensor (constructor: Tensor(data) → Tensor) ----
	exports["Tensor"] = make_callable_type(reg,
		{Param_Type{name = "data", type_id = TYPE_ANY}},
		tensor_f64)

	vreg.modules["mimir.ml"] = Virtual_Module{
		name    = "mimir.ml",
		exports = exports,
	}
}
