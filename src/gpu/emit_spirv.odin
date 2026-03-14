package gpu

import "core:mem"
import "core:fmt"

import checker "mimir:checker"

// SPIR-V binary compute shader emission.
// Encodes a valid SPIR-V module directly — no external tools needed.

// SPIR-V opcodes (subset needed for compute kernels)
SPIRV_OP_CAPABILITY       :: 17
SPIRV_OP_EXT_INST_IMPORT  :: 11
SPIRV_OP_EXT_INST         :: 12
SPIRV_OP_MEMORY_MODEL     :: 14
SPIRV_OP_ENTRY_POINT      :: 15
SPIRV_OP_EXECUTION_MODE   :: 16
SPIRV_OP_NAME             :: 5
SPIRV_OP_DECORATE         :: 71
SPIRV_OP_MEMBER_DECORATE  :: 72
SPIRV_OP_TYPE_VOID        :: 19
SPIRV_OP_TYPE_BOOL        :: 20
SPIRV_OP_TYPE_INT         :: 21
SPIRV_OP_TYPE_FLOAT       :: 22
SPIRV_OP_TYPE_VECTOR      :: 23
SPIRV_OP_TYPE_ARRAY       :: 28
SPIRV_OP_TYPE_RUNTIME_ARRAY :: 29
SPIRV_OP_TYPE_STRUCT       :: 30
SPIRV_OP_TYPE_POINTER      :: 32
SPIRV_OP_TYPE_FUNCTION     :: 33
SPIRV_OP_CONSTANT          :: 43
SPIRV_OP_VARIABLE          :: 59
SPIRV_OP_LOAD              :: 61
SPIRV_OP_STORE             :: 62
SPIRV_OP_ACCESS_CHAIN      :: 65
SPIRV_OP_COMPOSITE_EXTRACT :: 81
SPIRV_OP_FADD              :: 129
SPIRV_OP_FSUB              :: 131
SPIRV_OP_FMUL              :: 133
SPIRV_OP_FDIV              :: 136
SPIRV_OP_FNEGATE           :: 127
SPIRV_OP_SELECT            :: 169
SPIRV_OP_FORD_LESS_THAN    :: 184
SPIRV_OP_FORD_GREATER_THAN :: 186
SPIRV_OP_FORD_LESS_THAN_EQ :: 188
SPIRV_OP_FORD_GREATER_THAN_EQ :: 190
SPIRV_OP_FORD_EQUAL        :: 180
SPIRV_OP_LABEL             :: 248
SPIRV_OP_RETURN            :: 253
SPIRV_OP_FUNCTION_END      :: 56
SPIRV_OP_FUNCTION          :: 54
SPIRV_OP_FUNCTION_PARAMETER :: 55

// Decoration constants
SPIRV_DEC_BINDING         :: 33
SPIRV_DEC_DESCRIPTOR_SET  :: 34
SPIRV_DEC_BUILTIN         :: 11
SPIRV_DEC_BLOCK           :: 2
SPIRV_DEC_ARRAY_STRIDE    :: 6
SPIRV_DEC_OFFSET          :: 35

// Capability & addressing
SPIRV_CAP_SHADER          :: 1
SPIRV_ADDR_LOGICAL        :: 0
SPIRV_MEM_GLSL450         :: 1
SPIRV_EXEC_LOCAL_SIZE     :: 17

// Storage classes
SPIRV_SC_UNIFORM_CONSTANT :: 0
SPIRV_SC_INPUT            :: 1
SPIRV_SC_UNIFORM          :: 2
SPIRV_SC_OUTPUT           :: 3
SPIRV_SC_STORAGE_BUFFER   :: 12
SPIRV_SC_FUNCTION         :: 7

// Builtins
SPIRV_BUILTIN_GLOBAL_INVOCATION_ID :: 28

// GLSL.std.450 extended instruction set opcodes
SPIRV_GLSL_FABS  :: 4
SPIRV_GLSL_EXP   :: 27
SPIRV_GLSL_FMAX  :: 40
SPIRV_GLSL_TANH  :: 21

SPIRV_Module :: struct {
	next_id:      u32,
	capabilities: [dynamic]u32,
	extensions:   [dynamic]u32,
	imports:      [dynamic]u32,
	memory_model: [dynamic]u32,
	entry_points: [dynamic]u32,
	exec_modes:   [dynamic]u32,
	annotations:  [dynamic]u32,
	names:        [dynamic]u32,
	types:        [dynamic]u32,
	globals:      [dynamic]u32,
	functions:    [dynamic]u32,
	allocator:    mem.Allocator,
}

spirv_init :: proc(allocator: mem.Allocator) -> SPIRV_Module {
	return SPIRV_Module{
		next_id      = 1,
		capabilities = make([dynamic]u32, 0, 64, allocator),
		extensions   = make([dynamic]u32, 0, 16, allocator),
		imports      = make([dynamic]u32, 0, 32, allocator),
		memory_model = make([dynamic]u32, 0, 8, allocator),
		entry_points = make([dynamic]u32, 0, 32, allocator),
		exec_modes   = make([dynamic]u32, 0, 16, allocator),
		annotations  = make([dynamic]u32, 0, 128, allocator),
		names        = make([dynamic]u32, 0, 64, allocator),
		types        = make([dynamic]u32, 0, 256, allocator),
		globals      = make([dynamic]u32, 0, 128, allocator),
		functions    = make([dynamic]u32, 0, 512, allocator),
		allocator    = allocator,
	}
}

spirv_alloc_id :: proc(m: ^SPIRV_Module) -> u32 {
	id := m.next_id
	m.next_id += 1
	return id
}

// Emit a SPIR-V instruction: (word_count << 16) | opcode, then operands.
spirv_emit :: proc(section: ^[dynamic]u32, opcode: u32, operands: ..u32) {
	word_count := u32(len(operands) + 1)
	append(section, (word_count << 16) | opcode)
	for op in operands {
		append(section, op)
	}
}

// Emit a string as SPIR-V words (null-padded to 4-byte boundary).
spirv_emit_string :: proc(section: ^[dynamic]u32, s: string) {
	bytes := transmute([]u8)s
	word: u32 = 0
	byte_idx: u32 = 0
	for i := 0; i < len(bytes); i += 1 {
		word |= u32(bytes[i]) << (byte_idx * 8)
		byte_idx += 1
		if byte_idx == 4 {
			append(section, word)
			word = 0
			byte_idx = 0
		}
	}
	// Always append final word (includes null terminator via zero-init)
	append(section, word)
}

// Emit OpName for debugging.
spirv_emit_name :: proc(m: ^SPIRV_Module, id: u32, name: string) {
	start := len(m.names)
	// Placeholder for instruction header
	append(&m.names, 0)
	append(&m.names, id)
	spirv_emit_string(&m.names, name)
	word_count := u32(len(m.names) - start)
	m.names[start] = (word_count << 16) | SPIRV_OP_NAME
}

// Emit OpEntryPoint GLCompute.
spirv_emit_entry_point :: proc(m: ^SPIRV_Module, func_id: u32, name: string, interfaces: ..u32) {
	start := len(m.entry_points)
	append(&m.entry_points, 0) // placeholder
	append(&m.entry_points, 5) // GLCompute
	append(&m.entry_points, func_id)
	spirv_emit_string(&m.entry_points, name)
	for iface in interfaces {
		append(&m.entry_points, iface)
	}
	word_count := u32(len(m.entry_points) - start)
	m.entry_points[start] = (word_count << 16) | SPIRV_OP_ENTRY_POINT
}

emit_spirv :: proc(
	graph: ^Compute_Graph,
	type_ctx: ^GPU_Type_Context,
	bindings: ^Binding_Info,
	allocator: mem.Allocator,
) -> []u8 {
	m := spirv_init(allocator)

	// --- Preamble ---
	spirv_emit(&m.capabilities, SPIRV_OP_CAPABILITY, SPIRV_CAP_SHADER)

	// Import GLSL.std.450
	glsl_id := spirv_alloc_id(&m)
	{
		start := len(m.imports)
		append(&m.imports, 0)
		append(&m.imports, glsl_id)
		spirv_emit_string(&m.imports, "GLSL.std.450")
		word_count := u32(len(m.imports) - start)
		m.imports[start] = (word_count << 16) | SPIRV_OP_EXT_INST_IMPORT
	}

	spirv_emit(&m.memory_model, SPIRV_OP_MEMORY_MODEL, SPIRV_ADDR_LOGICAL, SPIRV_MEM_GLSL450)

	// --- Types ---
	void_id := spirv_alloc_id(&m)
	spirv_emit(&m.types, SPIRV_OP_TYPE_VOID, void_id)

	float_id := spirv_alloc_id(&m)
	spirv_emit(&m.types, SPIRV_OP_TYPE_FLOAT, float_id, 32)

	bool_type_id := spirv_alloc_id(&m)
	spirv_emit(&m.types, SPIRV_OP_TYPE_BOOL, bool_type_id)

	uint_id := spirv_alloc_id(&m)
	spirv_emit(&m.types, SPIRV_OP_TYPE_INT, uint_id, 32, 0) // 32-bit unsigned

	uvec3_id := spirv_alloc_id(&m)
	spirv_emit(&m.types, SPIRV_OP_TYPE_VECTOR, uvec3_id, uint_id, 3)

	// Runtime array of float
	rtarr_id := spirv_alloc_id(&m)
	spirv_emit(&m.types, SPIRV_OP_TYPE_RUNTIME_ARRAY, rtarr_id, float_id)
	// ArrayStride 4
	spirv_emit(&m.annotations, SPIRV_OP_DECORATE, rtarr_id, SPIRV_DEC_ARRAY_STRIDE, 4)

	// Struct wrapping runtime array (for each buffer)
	buf_struct_id := spirv_alloc_id(&m)
	spirv_emit(&m.types, SPIRV_OP_TYPE_STRUCT, buf_struct_id, rtarr_id)
	spirv_emit(&m.annotations, SPIRV_OP_DECORATE, buf_struct_id, SPIRV_DEC_BLOCK)
	spirv_emit(&m.annotations, SPIRV_OP_MEMBER_DECORATE, buf_struct_id, 0, SPIRV_DEC_OFFSET, 0)

	// Pointers
	ptr_buf_id := spirv_alloc_id(&m)
	spirv_emit(&m.types, SPIRV_OP_TYPE_POINTER, ptr_buf_id, SPIRV_SC_STORAGE_BUFFER, buf_struct_id)

	ptr_float_id := spirv_alloc_id(&m)
	spirv_emit(&m.types, SPIRV_OP_TYPE_POINTER, ptr_float_id, SPIRV_SC_STORAGE_BUFFER, float_id)

	ptr_uvec3_input_id := spirv_alloc_id(&m)
	spirv_emit(&m.types, SPIRV_OP_TYPE_POINTER, ptr_uvec3_input_id, SPIRV_SC_INPUT, uvec3_id)

	ptr_uint_input_id := spirv_alloc_id(&m)
	spirv_emit(&m.types, SPIRV_OP_TYPE_POINTER, ptr_uint_input_id, SPIRV_SC_INPUT, uint_id)

	// Function type: void()
	func_type_id := spirv_alloc_id(&m)
	spirv_emit(&m.types, SPIRV_OP_TYPE_FUNCTION, func_type_id, void_id)

	// Constants
	const_0_uint := spirv_alloc_id(&m)
	spirv_emit(&m.types, SPIRV_OP_CONSTANT, uint_id, const_0_uint, 0)

	const_0_float := spirv_alloc_id(&m)
	spirv_emit(&m.types, SPIRV_OP_CONSTANT, float_id, const_0_float, 0)

	const_1_float := spirv_alloc_id(&m)
	spirv_emit(&m.types, SPIRV_OP_CONSTANT, float_id, const_1_float, 0x3F800000) // 1.0f

	// --- GlobalInvocationId ---
	gid_var := spirv_alloc_id(&m)
	spirv_emit(&m.globals, SPIRV_OP_VARIABLE, ptr_uvec3_input_id, gid_var, SPIRV_SC_INPUT)
	spirv_emit(&m.annotations, SPIRV_OP_DECORATE, gid_var, SPIRV_DEC_BUILTIN, SPIRV_BUILTIN_GLOBAL_INVOCATION_ID)

	// --- Buffer variables ---
	param_var_ids := make(map[GPU_Node_ID]u32, len(graph.inputs), allocator)
	for inp in graph.inputs {
		var_id := spirv_alloc_id(&m)
		spirv_emit(&m.globals, SPIRV_OP_VARIABLE, ptr_buf_id, var_id, SPIRV_SC_STORAGE_BUFFER)
		binding := bindings.param_bindings[inp]
		spirv_emit(&m.annotations, SPIRV_OP_DECORATE, var_id, SPIRV_DEC_DESCRIPTOR_SET, 0)
		spirv_emit(&m.annotations, SPIRV_OP_DECORATE, var_id, SPIRV_DEC_BINDING, u32(binding))
		param_var_ids[inp] = var_id
		node := get_node(graph, inp)
		if node != nil {
			spirv_emit_name(&m, var_id, node.name)
		}
	}

	output_var_ids := make(map[GPU_Node_ID]u32, len(graph.outputs), allocator)
	for out in graph.outputs {
		var_id := spirv_alloc_id(&m)
		spirv_emit(&m.globals, SPIRV_OP_VARIABLE, ptr_buf_id, var_id, SPIRV_SC_STORAGE_BUFFER)
		binding := bindings.output_bindings[out]
		spirv_emit(&m.annotations, SPIRV_OP_DECORATE, var_id, SPIRV_DEC_DESCRIPTOR_SET, 0)
		spirv_emit(&m.annotations, SPIRV_OP_DECORATE, var_id, SPIRV_DEC_BINDING, u32(binding))
		output_var_ids[out] = var_id
		spirv_emit_name(&m, var_id, "result")
	}

	// --- Entry point ---
	func_id := spirv_alloc_id(&m)
	spirv_emit_entry_point(&m, func_id, "main", gid_var)
	spirv_emit(&m.exec_modes, SPIRV_OP_EXECUTION_MODE, func_id, SPIRV_EXEC_LOCAL_SIZE, 64, 1, 1)
	spirv_emit_name(&m, func_id, "main")

	// --- Function body ---
	label_id := spirv_alloc_id(&m)
	spirv_emit(&m.functions, SPIRV_OP_FUNCTION, void_id, func_id, 0, func_type_id)
	spirv_emit(&m.functions, SPIRV_OP_LABEL, label_id)

	// Load global invocation ID → extract .x as thread index
	gid_loaded := spirv_alloc_id(&m)
	spirv_emit(&m.functions, SPIRV_OP_LOAD, uvec3_id, gid_loaded, gid_var)

	tid_id := spirv_alloc_id(&m)
	spirv_emit(&m.functions, SPIRV_OP_COMPOSITE_EXTRACT, uint_id, tid_id, gid_loaded, 0)

	// Map: graph node ID → SPIR-V result ID
	node_ids := make(map[GPU_Node_ID]u32, len(graph.nodes), allocator)

	// Emit each node
	for &node in graph.nodes {
		result_id := spirv_emit_graph_node(&m, graph, &node, &node_ids, &param_var_ids,
			float_id, uint_id, bool_type_id, ptr_float_id, const_0_uint, const_0_float, const_1_float,
			tid_id, glsl_id, allocator)
		if result_id != 0 {
			node_ids[node.id] = result_id
		}
	}

	// Store outputs
	for out in graph.outputs {
		out_var := output_var_ids[out]
		out_val := node_ids[out]
		if out_val == 0 { continue }
		// AccessChain into runtime array
		ptr_id := spirv_alloc_id(&m)
		spirv_emit(&m.functions, SPIRV_OP_ACCESS_CHAIN, ptr_float_id, ptr_id, out_var, const_0_uint, tid_id)
		spirv_emit(&m.functions, SPIRV_OP_STORE, ptr_id, out_val)
	}

	spirv_emit(&m.functions, SPIRV_OP_RETURN)
	spirv_emit(&m.functions, SPIRV_OP_FUNCTION_END)

	// --- Assemble ---
	return spirv_assemble(&m, allocator)
}

spirv_emit_graph_node :: proc(
	m: ^SPIRV_Module,
	graph: ^Compute_Graph,
	node: ^GPU_Node,
	node_ids: ^map[GPU_Node_ID]u32,
	param_var_ids: ^map[GPU_Node_ID]u32,
	float_id, uint_id, bool_type_id, ptr_float_id, const_0_uint, const_0_float, const_1_float: u32,
	tid_id: u32,
	glsl_id: u32,
	allocator: mem.Allocator,
) -> u32 {

	// Helper: get SPIR-V ID for a graph input
	get_input :: proc(
		m: ^SPIRV_Module,
		nid: GPU_Node_ID,
		graph: ^Compute_Graph,
		node_ids: ^map[GPU_Node_ID]u32,
		param_var_ids: ^map[GPU_Node_ID]u32,
		float_id, ptr_float_id, const_0_uint, const_0_float, tid_id: u32,
	) -> u32 {
		// Already computed?
		if val, ok := node_ids[nid]; ok {
			return val
		}
		// Param node: load from buffer
		in_node := get_node(graph, nid)
		if in_node != nil && in_node.kind == .Param {
			if var_id, ok2 := param_var_ids[nid]; ok2 {
				ptr := spirv_alloc_id(m)
				spirv_emit(&m.functions, SPIRV_OP_ACCESS_CHAIN, ptr_float_id, ptr, var_id, const_0_uint, tid_id)
				val := spirv_alloc_id(m)
				spirv_emit(&m.functions, SPIRV_OP_LOAD, float_id, val, ptr)
				(^map[GPU_Node_ID]u32)(node_ids)[nid] = val
				return val
			}
		}
		return const_0_float
	}

	switch node.kind {
	case .Param:
		// Loaded on demand via get_input
		return 0

	case .Constant:
		result := spirv_alloc_id(m)
		// Encode float constant
		spirv_emit(&m.types, SPIRV_OP_CONSTANT, float_id, result, spirv_float_bits(node.name))
		return result

	case .Add:
		a := get_input(m, node.inputs[0], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		b := get_input(m, node.inputs[1], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		result := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_FADD, float_id, result, a, b)
		return result

	case .Sub:
		a := get_input(m, node.inputs[0], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		b := get_input(m, node.inputs[1], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		result := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_FSUB, float_id, result, a, b)
		return result

	case .Mul:
		a := get_input(m, node.inputs[0], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		b := get_input(m, node.inputs[1], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		result := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_FMUL, float_id, result, a, b)
		return result

	case .Div:
		a := get_input(m, node.inputs[0], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		b := get_input(m, node.inputs[1], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		result := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_FDIV, float_id, result, a, b)
		return result

	case .Neg:
		a := get_input(m, node.inputs[0], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		result := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_FNEGATE, float_id, result, a)
		return result

	case .Abs:
		a := get_input(m, node.inputs[0], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		result := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_EXT_INST, float_id, result, glsl_id, SPIRV_GLSL_FABS, a)
		return result

	case .ReLU:
		a := get_input(m, node.inputs[0], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		result := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_EXT_INST, float_id, result, glsl_id, SPIRV_GLSL_FMAX, a, const_0_float)
		return result

	case .Sigmoid:
		a := get_input(m, node.inputs[0], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		neg := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_FNEGATE, float_id, neg, a)
		exp_val := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_EXT_INST, float_id, exp_val, glsl_id, SPIRV_GLSL_EXP, neg)
		plus1 := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_FADD, float_id, plus1, const_1_float, exp_val)
		result := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_FDIV, float_id, result, const_1_float, plus1)
		return result

	case .Tanh:
		a := get_input(m, node.inputs[0], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		result := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_EXT_INST, float_id, result, glsl_id, SPIRV_GLSL_TANH, a)
		return result

	case .Equal:
		a := get_input(m, node.inputs[0], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		b := get_input(m, node.inputs[1], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		bool_id := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_FORD_EQUAL, bool_type_id, bool_id, a, b)
		result := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_SELECT, float_id, result, bool_id, const_1_float, const_0_float)
		return result

	case .Less:
		a := get_input(m, node.inputs[0], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		b := get_input(m, node.inputs[1], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		bool_id := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_FORD_LESS_THAN, bool_type_id, bool_id, a, b)
		result := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_SELECT, float_id, result, bool_id, const_1_float, const_0_float)
		return result

	case .Greater:
		a := get_input(m, node.inputs[0], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		b := get_input(m, node.inputs[1], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		bool_id := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_FORD_GREATER_THAN, bool_type_id, bool_id, a, b)
		result := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_SELECT, float_id, result, bool_id, const_1_float, const_0_float)
		return result

	case .LessEq:
		a := get_input(m, node.inputs[0], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		b := get_input(m, node.inputs[1], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		bool_id := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_FORD_LESS_THAN_EQ, bool_type_id, bool_id, a, b)
		result := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_SELECT, float_id, result, bool_id, const_1_float, const_0_float)
		return result

	case .GreaterEq:
		a := get_input(m, node.inputs[0], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		b := get_input(m, node.inputs[1], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		bool_id := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_FORD_GREATER_THAN_EQ, bool_type_id, bool_id, a, b)
		result := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_SELECT, float_id, result, bool_id, const_1_float, const_0_float)
		return result

	case .Select:
		if len(node.inputs) >= 3 {
			cond := get_input(m, node.inputs[0], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
			tv := get_input(m, node.inputs[1], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
			fv := get_input(m, node.inputs[2], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
			// cond > 0 as bool
			cond_bool := spirv_alloc_id(m)
			spirv_emit(&m.functions, SPIRV_OP_FORD_GREATER_THAN, float_id, cond_bool, cond, const_0_float)
			result := spirv_alloc_id(m)
			spirv_emit(&m.functions, SPIRV_OP_SELECT, float_id, result, cond_bool, tv, fv)
			return result
		}
		return const_0_float

	case .Softmax:
		a := get_input(m, node.inputs[0], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		result := spirv_alloc_id(m)
		spirv_emit(&m.functions, SPIRV_OP_EXT_INST, float_id, result, glsl_id, SPIRV_GLSL_EXP, a)
		return result

	case .MatMul, .Transpose, .Sum, .Mean, .Max, .Min, .Reshape, .Broadcast:
		// Complex ops: passthrough first input for now
		if len(node.inputs) > 0 {
			return get_input(m, node.inputs[0], graph, node_ids, param_var_ids, float_id, ptr_float_id, const_0_uint, const_0_float, tid_id)
		}
		return const_0_float
	}

	return 0
}

// Parse a float constant string to IEEE 754 bits.
spirv_float_bits :: proc(s: string) -> u32 {
	val: f32 = 0.0
	negative := false
	i := 0
	bytes := transmute([]u8)s

	if i < len(bytes) && bytes[i] == '-' {
		negative = true
		i += 1
	}

	// Integer part
	for i < len(bytes) && bytes[i] >= '0' && bytes[i] <= '9' {
		val = val * 10.0 + f32(bytes[i] - '0')
		i += 1
	}

	// Fractional part
	if i < len(bytes) && bytes[i] == '.' {
		i += 1
		frac: f32 = 0.1
		for i < len(bytes) && bytes[i] >= '0' && bytes[i] <= '9' {
			val += f32(bytes[i] - '0') * frac
			frac *= 0.1
			i += 1
		}
	}

	if negative { val = -val }
	return transmute(u32)val
}

// Assemble all sections into final SPIR-V binary.
spirv_assemble :: proc(m: ^SPIRV_Module, allocator: mem.Allocator) -> []u8 {
	total_words := 5 // header
	total_words += len(m.capabilities)
	total_words += len(m.extensions)
	total_words += len(m.imports)
	total_words += len(m.memory_model)
	total_words += len(m.entry_points)
	total_words += len(m.exec_modes)
	total_words += len(m.names)
	total_words += len(m.annotations)
	total_words += len(m.types)
	total_words += len(m.globals)
	total_words += len(m.functions)

	words := make([dynamic]u32, 0, total_words, allocator)

	// Header
	append(&words, 0x07230203) // Magic
	append(&words, 0x00010500) // Version 1.5
	append(&words, 0x00000000) // Generator (0 = custom)
	append(&words, m.next_id)  // Bound
	append(&words, 0)          // Schema

	// Sections in required order
	for w in m.capabilities { append(&words, w) }
	for w in m.extensions   { append(&words, w) }
	for w in m.imports      { append(&words, w) }
	for w in m.memory_model { append(&words, w) }
	for w in m.entry_points { append(&words, w) }
	for w in m.exec_modes   { append(&words, w) }
	for w in m.names        { append(&words, w) }
	for w in m.annotations  { append(&words, w) }
	for w in m.types        { append(&words, w) }
	for w in m.globals      { append(&words, w) }
	for w in m.functions    { append(&words, w) }

	// Convert to bytes (little-endian native)
	byte_count := len(words) * 4
	result := make([]u8, byte_count, allocator)
	word_slice := words[:]
	raw_bytes := transmute([]u8)mem.Raw_Slice{raw_data(word_slice), byte_count}
	copy(result, raw_bytes)

	return result
}
