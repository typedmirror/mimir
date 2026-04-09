package checker

// ==================== Tensor/Array Attribute Resolution ====================
//
// Attribute and method resolution for Tensor_Type (mimir.array).
// Properties: .shape, .ndim, .dtype, .size, .T
// Methods: .reshape(), .sum(), .mean(), .min(), .max(), .flatten(),
//          .squeeze(), .astype(), .tolist(), .copy()

// Resolve Tensor attribute access — properties and methods.
resolve_tensor_attr :: proc(reg: ^Type_Registry, tensor: ^Tensor_Type, attr: string) -> Type_ID {
	no_params := make([]Param_Type, 0, reg.allocator)
	same_tensor := make_tensor_type(reg, tensor.element_type, {})

	switch attr {
	// Properties
	case "shape":
		if len(tensor.shape) > 0 {
			// Known shape → concrete tuple
			elts := make([]Type_ID, len(tensor.shape), reg.allocator)
			for i in 0..<len(tensor.shape) { elts[i] = TYPE_INT }
			return make_tuple_type(reg, elts, false)
		}
		return make_tuple_type(reg, {TYPE_INT}, true) // variable-length tuple of ints
	case "ndim":
		return TYPE_INT
	case "dtype":
		return TYPE_STR
	case "size":
		return TYPE_INT
	case "T":
		return same_tensor
	case "flat":
		return make_tensor_type(reg, tensor.element_type, {})

	// Reduction methods → scalar or tensor depending on axis
	case "sum", "prod":
		return make_callable_type(reg,
			{Param_Type{name = "axis", type_id = TYPE_INT, has_default = true}},
			tensor.element_type) // scalar when no axis
	case "mean", "std", "var":
		return make_callable_type(reg,
			{Param_Type{name = "axis", type_id = TYPE_INT, has_default = true}},
			TYPE_FLOAT)
	case "min", "max":
		return make_callable_type(reg,
			{Param_Type{name = "axis", type_id = TYPE_INT, has_default = true}},
			tensor.element_type)
	case "argmin", "argmax":
		return make_callable_type(reg,
			{Param_Type{name = "axis", type_id = TYPE_INT, has_default = true}},
			TYPE_INT)
	case "cumsum", "cumprod":
		return make_callable_type(reg,
			{Param_Type{name = "axis", type_id = TYPE_INT, has_default = true}},
			same_tensor)

	// Shape manipulation methods
	case "reshape":
		return make_callable_type(reg,
			{Param_Type{name = "shape", type_id = TYPE_ANY}},
			same_tensor)
	case "flatten":
		return make_callable_type(reg, no_params,
			make_tensor_type(reg, tensor.element_type, {}))
	case "squeeze":
		return make_callable_type(reg,
			{Param_Type{name = "axis", type_id = TYPE_INT, has_default = true}},
			same_tensor)
	case "transpose":
		return make_callable_type(reg,
			{Param_Type{name = "axes", type_id = TYPE_ANY, has_default = true}},
			same_tensor)
	case "ravel":
		return make_callable_type(reg, no_params,
			make_tensor_type(reg, tensor.element_type, {}))
	case "swapaxes":
		return make_callable_type(reg,
			{Param_Type{name = "axis1", type_id = TYPE_INT}, Param_Type{name = "axis2", type_id = TYPE_INT}},
			same_tensor)

	// Type conversion
	case "astype":
		return make_callable_type(reg,
			{Param_Type{name = "dtype", type_id = TYPE_ANY}},
			make_tensor_type(reg, TYPE_ANY, {})) // element type changes

	// Copy / conversion
	case "copy":
		return make_callable_type(reg, no_params, same_tensor)
	case "tolist":
		return make_callable_type(reg, no_params, make_list_type(reg, tensor.element_type))
	case "item":
		return make_callable_type(reg, no_params, tensor.element_type)

	// Device transfer (PyTorch-compatible) — returns tensor with device field set
	case "cuda":
		cuda_tensor := register_type(reg, Tensor_Type{
			element_type = tensor.element_type, shape = tensor.shape, ndim = tensor.ndim,
			device = .CUDA,
		})
		return make_callable_type(reg, no_params, cuda_tensor)
	case "cpu":
		cpu_tensor := register_type(reg, Tensor_Type{
			element_type = tensor.element_type, shape = tensor.shape, ndim = tensor.ndim,
			device = .CPU,
		})
		return make_callable_type(reg, no_params, cpu_tensor)
	case "to":
		// .to("cuda") / .to("cpu") — device resolved at constraint level, return same shape
		return make_callable_type(reg,
			{Param_Type{name = "device", type_id = TYPE_STR}},
			same_tensor)
	case "device":
		return TYPE_STR
	case "is_cuda":
		return TYPE_BOOL

	// Boolean methods
	case "any":
		return make_callable_type(reg,
			{Param_Type{name = "axis", type_id = TYPE_INT, has_default = true}},
			TYPE_BOOL)
	case "all":
		return make_callable_type(reg,
			{Param_Type{name = "axis", type_id = TYPE_INT, has_default = true}},
			TYPE_BOOL)

	// Dot product / matmul
	case "dot":
		return make_callable_type(reg,
			{Param_Type{name = "b", type_id = same_tensor}},
			same_tensor)

	// Fill
	case "fill":
		return make_callable_type(reg,
			{Param_Type{name = "value", type_id = tensor.element_type}},
			TYPE_NONE)

	// Clip
	case "clip":
		return make_callable_type(reg,
			{
				Param_Type{name = "min", type_id = tensor.element_type, has_default = true},
				Param_Type{name = "max", type_id = tensor.element_type, has_default = true},
			},
			same_tensor)

	// Round
	case "round":
		return make_callable_type(reg,
			{Param_Type{name = "decimals", type_id = TYPE_INT, has_default = true}},
			same_tensor)

	// Autograd (mimir.ml tensor extensions)
	case "backward":
		return make_callable_type(reg, no_params, TYPE_NONE)
	case "grad":
		return same_tensor
	case "requires_grad":
		return TYPE_BOOL
	case "detach":
		return make_callable_type(reg, no_params, same_tensor)
	}

	return TYPE_UNKNOWN
}
