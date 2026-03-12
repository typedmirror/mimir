package gpu

import "core:mem"
import "core:fmt"

import checker "mimir:checker"

// Autograd — reverse-mode automatic differentiation at compile time.
// Given a forward Compute_Graph, produce a backward Compute_Graph whose
// inputs are the forward outputs' gradients and whose outputs are the
// forward inputs' gradients.

Grad_Context :: struct {
	forward:   ^Compute_Graph,
	backward:  ^Compute_Graph,
	type_ctx:  ^GPU_Type_Context,
	grad_map:  map[GPU_Node_ID]GPU_Node_ID, // forward node → its accumulated gradient in backward
	allocator: mem.Allocator,
}

// Generate a backward pass compute graph from a forward graph.
generate_backward :: proc(
	forward: ^Compute_Graph,
	type_ctx: ^GPU_Type_Context,
	allocator: mem.Allocator,
) -> Compute_Graph {
	backward := Compute_Graph{
		nodes     = make([dynamic]GPU_Node, 0, len(forward.nodes) * 2, allocator),
		inputs    = make([dynamic]GPU_Node_ID, 0, len(forward.outputs), allocator),
		outputs   = make([dynamic]GPU_Node_ID, 0, len(forward.inputs), allocator),
		func_name = fmt.tprintf("%s_backward", forward.func_name),
		allocator = allocator,
	}

	ctx := Grad_Context{
		forward   = forward,
		backward  = &backward,
		type_ctx  = type_ctx,
		grad_map  = make(map[GPU_Node_ID]GPU_Node_ID, len(forward.nodes), allocator),
		allocator = allocator,
	}

	// Step 1: Create Param nodes in backward graph for each forward output's gradient
	for fwd_out in forward.outputs {
		fwd_node := get_node(forward, fwd_out)
		grad_param := add_node(&backward, GPU_Node{
			kind         = .Param,
			output_type  = fwd_node.output_type if fwd_node != nil else checker.TYPE_FLOAT,
			output_shape = fwd_node.output_shape if fwd_node != nil else nil,
			name         = fmt.tprintf("grad_%d", int(fwd_out)),
		})
		append(&backward.inputs, grad_param)
		ctx.grad_map[fwd_out] = grad_param
	}

	// Step 2: Walk forward nodes in REVERSE order (reverse topological)
	for i := len(forward.nodes) - 1; i >= 0; i -= 1 {
		node := &forward.nodes[i]
		// Skip if this node has no gradient (not reachable from outputs)
		output_grad, has_grad := ctx.grad_map[node.id]
		if !has_grad { continue }
		// Skip nodes with no inputs (Param/Constant — their grad is the output)
		if node.kind == .Param || node.kind == .Constant { continue }

		differentiate_node(&ctx, node, output_grad)
	}

	// Step 3: For each forward Param, its grad_map entry is the parameter gradient
	for fwd_inp in forward.inputs {
		if grad_id, ok := ctx.grad_map[fwd_inp]; ok {
			append(&backward.outputs, grad_id)
		}
	}

	return backward
}

// Apply derivative rule for a single node, producing gradient contributions.
differentiate_node :: proc(ctx: ^Grad_Context, node: ^GPU_Node, output_grad: GPU_Node_ID) {
	#partial switch node.kind {
	case .Add:
		// d/da = grad, d/db = grad
		if len(node.inputs) >= 2 {
			accumulate_grad(ctx, node.inputs[0], output_grad)
			accumulate_grad(ctx, node.inputs[1], output_grad)
		}

	case .Sub:
		// d/da = grad, d/db = -grad
		if len(node.inputs) >= 2 {
			accumulate_grad(ctx, node.inputs[0], output_grad)
			neg_grad := make_unary(ctx, .Neg, output_grad, node)
			accumulate_grad(ctx, node.inputs[1], neg_grad)
		}

	case .Mul:
		// d/da = grad * b, d/db = grad * a
		if len(node.inputs) >= 2 {
			// We need to reference forward nodes — use Param nodes that mirror them
			b_ref := make_forward_ref(ctx, node.inputs[1])
			a_ref := make_forward_ref(ctx, node.inputs[0])
			grad_a := make_binary(ctx, .Mul, output_grad, b_ref, node)
			grad_b := make_binary(ctx, .Mul, output_grad, a_ref, node)
			accumulate_grad(ctx, node.inputs[0], grad_a)
			accumulate_grad(ctx, node.inputs[1], grad_b)
		}

	case .Div:
		// d/da = grad / b
		// d/db = -grad * a / (b * b)
		if len(node.inputs) >= 2 {
			b_ref := make_forward_ref(ctx, node.inputs[1])
			a_ref := make_forward_ref(ctx, node.inputs[0])
			grad_a := make_binary(ctx, .Div, output_grad, b_ref, node)
			accumulate_grad(ctx, node.inputs[0], grad_a)
			// grad * a
			ga := make_binary(ctx, .Mul, output_grad, a_ref, node)
			// b * b
			bb := make_binary(ctx, .Mul, b_ref, b_ref, node)
			// ga / bb
			frac := make_binary(ctx, .Div, ga, bb, node)
			// -frac
			neg_frac := make_unary(ctx, .Neg, frac, node)
			accumulate_grad(ctx, node.inputs[1], neg_frac)
		}

	case .Neg:
		// d/da = -grad
		if len(node.inputs) >= 1 {
			neg_grad := make_unary(ctx, .Neg, output_grad, node)
			accumulate_grad(ctx, node.inputs[0], neg_grad)
		}

	case .Abs:
		// d/da = grad * sign(a) — approximate as Select(a > 0, 1, -1)
		if len(node.inputs) >= 1 {
			a_ref := make_forward_ref(ctx, node.inputs[0])
			// Create constant 1 and -1
			one := make_constant(ctx, "1", node)
			neg_one := make_unary(ctx, .Neg, one, node)
			// Select(a, 1, -1) — using a > 0 as condition
			zero := make_constant(ctx, "0", node)
			cond := make_binary(ctx, .Greater, a_ref, zero, node)
			sign := make_select(ctx, cond, one, neg_one, node)
			grad_a := make_binary(ctx, .Mul, output_grad, sign, node)
			accumulate_grad(ctx, node.inputs[0], grad_a)
		}

	case .MatMul:
		// d/dA = grad @ B^T, d/dB = A^T @ grad
		if len(node.inputs) >= 2 {
			b_ref := make_forward_ref(ctx, node.inputs[1])
			a_ref := make_forward_ref(ctx, node.inputs[0])
			bt := make_unary(ctx, .Transpose, b_ref, node)
			at := make_unary(ctx, .Transpose, a_ref, node)
			grad_a := make_binary(ctx, .MatMul, output_grad, bt, node)
			grad_b := make_binary(ctx, .MatMul, at, output_grad, node)
			accumulate_grad(ctx, node.inputs[0], grad_a)
			accumulate_grad(ctx, node.inputs[1], grad_b)
		}

	case .Transpose:
		// d/da = transpose(grad)
		if len(node.inputs) >= 1 {
			grad_t := make_unary(ctx, .Transpose, output_grad, node)
			accumulate_grad(ctx, node.inputs[0], grad_t)
		}

	case .ReLU:
		// d/da = grad * (a > 0)
		if len(node.inputs) >= 1 {
			a_ref := make_forward_ref(ctx, node.inputs[0])
			zero := make_constant(ctx, "0", node)
			one := make_constant(ctx, "1", node)
			cond := make_binary(ctx, .Greater, a_ref, zero, node)
			mask := make_select(ctx, cond, one, zero, node)
			grad_a := make_binary(ctx, .Mul, output_grad, mask, node)
			accumulate_grad(ctx, node.inputs[0], grad_a)
		}

	case .Sigmoid:
		// d/da = grad * sig * (1 - sig)   where sig = sigmoid(a)
		if len(node.inputs) >= 1 {
			sig_ref := make_forward_ref(ctx, node.id) // the sigmoid output itself
			one := make_constant(ctx, "1", node)
			one_minus_sig := make_binary(ctx, .Sub, one, sig_ref, node)
			sig_deriv := make_binary(ctx, .Mul, sig_ref, one_minus_sig, node)
			grad_a := make_binary(ctx, .Mul, output_grad, sig_deriv, node)
			accumulate_grad(ctx, node.inputs[0], grad_a)
		}

	case .Tanh:
		// d/da = grad * (1 - tanh^2(a))
		if len(node.inputs) >= 1 {
			th_ref := make_forward_ref(ctx, node.id)
			one := make_constant(ctx, "1", node)
			th_sq := make_binary(ctx, .Mul, th_ref, th_ref, node)
			one_minus := make_binary(ctx, .Sub, one, th_sq, node)
			grad_a := make_binary(ctx, .Mul, output_grad, one_minus, node)
			accumulate_grad(ctx, node.inputs[0], grad_a)
		}

	case .Sum:
		// d/da = broadcast(grad) to input shape
		if len(node.inputs) >= 1 {
			grad_bcast := make_unary(ctx, .Broadcast, output_grad, node)
			// Set shape from forward input
			fwd_inp := get_node(ctx.forward, node.inputs[0])
			bcast_node := get_node(ctx.backward, grad_bcast)
			if fwd_inp != nil && bcast_node != nil {
				bcast_node.output_shape = fwd_inp.output_shape
			}
			accumulate_grad(ctx, node.inputs[0], grad_bcast)
		}

	case .Mean:
		// d/da = broadcast(grad) / n
		if len(node.inputs) >= 1 {
			fwd_inp := get_node(ctx.forward, node.inputs[0])
			n_elem := 1
			if fwd_inp != nil && fwd_inp.output_shape != nil {
				n_elem = shape_product(fwd_inp.output_shape)
				if n_elem <= 0 { n_elem = 1 }
			}
			grad_bcast := make_unary(ctx, .Broadcast, output_grad, node)
			bcast_node := get_node(ctx.backward, grad_bcast)
			if fwd_inp != nil && bcast_node != nil {
				bcast_node.output_shape = fwd_inp.output_shape
			}
			n_const := make_constant_value(ctx, fmt.tprintf("%d", n_elem), node)
			grad_a := make_binary(ctx, .Div, grad_bcast, n_const, node)
			accumulate_grad(ctx, node.inputs[0], grad_a)
		}

	case .Max, .Min:
		// d/da = grad * (a == max/min(a)) — argmax/argmin mask
		if len(node.inputs) >= 1 {
			a_ref := make_forward_ref(ctx, node.inputs[0])
			result_ref := make_forward_ref(ctx, node.id)
			// Broadcast result to input shape for comparison
			result_bcast := make_unary(ctx, .Broadcast, result_ref, node)
			fwd_inp := get_node(ctx.forward, node.inputs[0])
			bcast_node := get_node(ctx.backward, result_bcast)
			if fwd_inp != nil && bcast_node != nil {
				bcast_node.output_shape = fwd_inp.output_shape
			}
			mask := make_binary(ctx, .Equal, a_ref, result_bcast, node)
			// Also broadcast grad
			grad_bcast := make_unary(ctx, .Broadcast, output_grad, node)
			gbcast_node := get_node(ctx.backward, grad_bcast)
			if fwd_inp != nil && gbcast_node != nil {
				gbcast_node.output_shape = fwd_inp.output_shape
			}
			grad_a := make_binary(ctx, .Mul, grad_bcast, mask, node)
			accumulate_grad(ctx, node.inputs[0], grad_a)
		}

	case .Softmax:
		// Simplified: grad * s - s * sum(grad * s)
		// where s = softmax output
		if len(node.inputs) >= 1 {
			s_ref := make_forward_ref(ctx, node.id)
			// grad * s
			gs := make_binary(ctx, .Mul, output_grad, s_ref, node)
			// sum(grad * s)
			sum_gs := make_unary(ctx, .Sum, gs, node)
			// s * sum(grad * s) — broadcast sum_gs first
			sum_bcast := make_unary(ctx, .Broadcast, sum_gs, node)
			fwd_inp := get_node(ctx.forward, node.inputs[0])
			sb := get_node(ctx.backward, sum_bcast)
			if fwd_inp != nil && sb != nil {
				sb.output_shape = fwd_inp.output_shape
			}
			s_sum := make_binary(ctx, .Mul, s_ref, sum_bcast, node)
			// result: grad * s - s * sum(grad * s)
			grad_a := make_binary(ctx, .Sub, gs, s_sum, node)
			accumulate_grad(ctx, node.inputs[0], grad_a)
		}

	case .Select:
		// d/d(true_val) = grad * cond, d/d(false_val) = grad * (1 - cond)
		if len(node.inputs) >= 3 {
			cond_ref := make_forward_ref(ctx, node.inputs[0])
			one := make_constant(ctx, "1", node)
			inv_cond := make_binary(ctx, .Sub, one, cond_ref, node)
			grad_true := make_binary(ctx, .Mul, output_grad, cond_ref, node)
			grad_false := make_binary(ctx, .Mul, output_grad, inv_cond, node)
			accumulate_grad(ctx, node.inputs[1], grad_true)
			accumulate_grad(ctx, node.inputs[2], grad_false)
		}

	case .Reshape:
		// d/da = reshape(grad) back to input shape
		if len(node.inputs) >= 1 {
			grad_reshape := make_unary(ctx, .Reshape, output_grad, node)
			fwd_inp := get_node(ctx.forward, node.inputs[0])
			rn := get_node(ctx.backward, grad_reshape)
			if fwd_inp != nil && rn != nil {
				rn.output_shape = fwd_inp.output_shape
			}
			accumulate_grad(ctx, node.inputs[0], grad_reshape)
		}

	case .Broadcast:
		// d/da = sum(grad) over broadcast dims
		if len(node.inputs) >= 1 {
			grad_sum := make_unary(ctx, .Sum, output_grad, node)
			accumulate_grad(ctx, node.inputs[0], grad_sum)
		}

	case .Equal, .Less, .Greater, .LessEq, .GreaterEq:
		// Non-differentiable — zero gradient (don't propagate)

	case:
		// Unknown op — don't propagate gradients
	}
}

// Accumulate gradient contribution. If grad_map[node_id] already exists, add.
accumulate_grad :: proc(ctx: ^Grad_Context, node_id: GPU_Node_ID, grad: GPU_Node_ID) {
	if existing, ok := ctx.grad_map[node_id]; ok {
		// Sum existing + new
		sum := make_binary(ctx, .Add, existing, grad, nil)
		ctx.grad_map[node_id] = sum
	} else {
		ctx.grad_map[node_id] = grad
	}
}

// Create a reference to a forward node's output in the backward graph.
// This creates a Param node that represents the forward value.
make_forward_ref :: proc(ctx: ^Grad_Context, fwd_id: GPU_Node_ID) -> GPU_Node_ID {
	fwd_node := get_node(ctx.forward, fwd_id)
	ref := add_node(ctx.backward, GPU_Node{
		kind         = .Param,
		output_type  = fwd_node.output_type if fwd_node != nil else checker.TYPE_FLOAT,
		output_shape = fwd_node.output_shape if fwd_node != nil else nil,
		name         = fmt.tprintf("fwd_%d", int(fwd_id)),
	})
	return ref
}

// Helper: create a unary op node in the backward graph.
make_unary :: proc(ctx: ^Grad_Context, kind: GPU_Op_Kind, input: GPU_Node_ID, ref_node: ^GPU_Node) -> GPU_Node_ID {
	inputs := make([]GPU_Node_ID, 1, ctx.allocator)
	inputs[0] = input
	inp_node := get_node(ctx.backward, input)
	return add_node(ctx.backward, GPU_Node{
		kind         = kind,
		inputs       = inputs,
		output_type  = inp_node.output_type if inp_node != nil else checker.TYPE_FLOAT,
		output_shape = inp_node.output_shape if inp_node != nil else nil,
	})
}

// Helper: create a binary op node in the backward graph.
make_binary :: proc(ctx: ^Grad_Context, kind: GPU_Op_Kind, left, right: GPU_Node_ID, ref_node: ^GPU_Node) -> GPU_Node_ID {
	inputs := make([]GPU_Node_ID, 2, ctx.allocator)
	inputs[0] = left
	inputs[1] = right
	left_node := get_node(ctx.backward, left)
	return add_node(ctx.backward, GPU_Node{
		kind         = kind,
		inputs       = inputs,
		output_type  = left_node.output_type if left_node != nil else checker.TYPE_FLOAT,
		output_shape = left_node.output_shape if left_node != nil else nil,
	})
}

// Helper: create a Select node in the backward graph.
make_select :: proc(ctx: ^Grad_Context, cond, true_val, false_val: GPU_Node_ID, ref_node: ^GPU_Node) -> GPU_Node_ID {
	inputs := make([]GPU_Node_ID, 3, ctx.allocator)
	inputs[0] = cond
	inputs[1] = true_val
	inputs[2] = false_val
	tv := get_node(ctx.backward, true_val)
	return add_node(ctx.backward, GPU_Node{
		kind         = .Select,
		inputs       = inputs,
		output_type  = tv.output_type if tv != nil else checker.TYPE_FLOAT,
		output_shape = tv.output_shape if tv != nil else nil,
	})
}

// Helper: create a constant "1" or "0" node.
make_constant :: proc(ctx: ^Grad_Context, value: string, ref_node: ^GPU_Node) -> GPU_Node_ID {
	return add_node(ctx.backward, GPU_Node{
		kind        = .Constant,
		output_type = checker.TYPE_FLOAT,
		name        = value,
	})
}

// Helper: create a constant with arbitrary string value.
make_constant_value :: proc(ctx: ^Grad_Context, value: string, ref_node: ^GPU_Node) -> GPU_Node_ID {
	return add_node(ctx.backward, GPU_Node{
		kind        = .Constant,
		output_type = checker.TYPE_FLOAT,
		name        = value,
	})
}
