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
