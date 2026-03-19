package gpu

import "core:mem"
import "core:fmt"

import checker "mimir:checker"

// Kernel Fusion — partition compute graphs into dispatch-compatible kernel groups.
// Elementwise chains fuse into one kernel; matmul and reduction require separate launches.

Dispatch_Kind :: enum {
	Elementwise_1D, // workgroup_size(64), tid.x
	MatMul_2D,      // workgroup_size(8,8), gid.xy
	Reduction,      // special dispatch (all threads → accumulate)
}

Kernel_Group :: struct {
	id:       int,
	node_ids: [dynamic]GPU_Node_ID,
	dispatch: Dispatch_Kind,
}

Fusion_Result :: struct {
	groups:    [dynamic]Kernel_Group,
	order:     []int, // execution order (topo-sorted group IDs)
	allocator: mem.Allocator,
}

// Classify a GPU op into its dispatch kind.
classify_dispatch :: proc(kind: GPU_Op_Kind) -> Dispatch_Kind {
	switch kind {
	case .MatMul:
		return .MatMul_2D
	case .Sum, .Mean, .Max, .Min, .Softmax:
		return .Reduction
	case .Conv2d:
		return .MatMul_2D // Conv2d uses 2D dispatch (output height × output width)
	case .Add, .Sub, .Mul, .Div, .Neg, .Abs,
	     .Equal, .NotEqual, .Less, .Greater, .LessEq, .GreaterEq,
	     .Transpose, .ReLU, .Sigmoid, .Tanh,
	     .Select, .Reshape, .Broadcast,
	     .Param, .Constant,
	     .BatchNorm, .Dropout, .Flatten,
	     .Exp, .Log, .Sqrt, .Pow, .Clamp:
		return .Elementwise_1D
	case .MaxPool2d, .AvgPool2d:
		return .Elementwise_1D // Pooling is per-output-element
	case .CrossEntropy:
		return .Reduction
	}
	return .Elementwise_1D
}

// Partition a compute graph into fusible kernel groups.
fuse_kernels :: proc(graph: ^Compute_Graph, allocator: mem.Allocator) -> Fusion_Result {
	result := Fusion_Result{
		groups    = make([dynamic]Kernel_Group, 0, 4, allocator),
		allocator = allocator,
	}

	if len(graph.nodes) == 0 {
		result.order = make([]int, 0, allocator)
		return result
	}

	// Map node → group index
	node_group := make(map[GPU_Node_ID]int, len(graph.nodes), allocator)

	// Walk nodes in order (already topological from extract_graph).
	// Start a new group whenever dispatch kind changes.
	current_group_idx := -1
	prev_dispatch := Dispatch_Kind.Elementwise_1D
	first := true

	for &node in graph.nodes {
		kind := classify_dispatch(node.kind)

		// Param and Constant inherit from first consumer — defer
		if node.kind == .Param || node.kind == .Constant {
			// Will be assigned to their consumer's group later
			continue
		}

		if first || kind != prev_dispatch {
			// Start a new group
			append(&result.groups, Kernel_Group{
				id       = len(result.groups),
				node_ids = make([dynamic]GPU_Node_ID, 0, 16, allocator),
				dispatch = kind,
			})
			current_group_idx = len(result.groups) - 1
			prev_dispatch = kind
			first = false
		}

		append(&result.groups[current_group_idx].node_ids, node.id)
		node_group[node.id] = current_group_idx
	}

	// Assign Param/Constant nodes to first consumer's group
	for &node in graph.nodes {
		if node.kind != .Param && node.kind != .Constant { continue }
		assigned := false
		// Find first consumer
		for &other in graph.nodes {
			if other.id == node.id { continue }
			for inp in other.inputs {
				if inp == node.id {
					if gidx, ok := node_group[other.id]; ok {
						node_group[node.id] = gidx
						append(&result.groups[gidx].node_ids, node.id)
						assigned = true
					}
					break
				}
			}
			if assigned { break }
		}
		// If no consumer found, put in first group
		if !assigned && len(result.groups) > 0 {
			node_group[node.id] = 0
			append(&result.groups[0].node_ids, node.id)
		}
	}

	// Topological sort groups by inter-group dependencies
	n_groups := len(result.groups)
	// Build group dependency edges
	dep_counts := make([]int, n_groups, allocator)
	group_deps := make([]([dynamic]int), n_groups, allocator)
	for i := 0; i < n_groups; i += 1 {
		group_deps[i] = make([dynamic]int, 0, 4, allocator)
	}

	// Check which groups depend on which
	dep_set := make(map[u64]bool, 32, allocator) // (from_group << 32 | to_group) dedup
	for &node in graph.nodes {
		ng, ng_ok := node_group[node.id]
		if !ng_ok { continue }
		for inp in node.inputs {
			ig, ig_ok := node_group[inp]
			if !ig_ok { continue }
			if ig != ng {
				key := u64(ig) << 32 | u64(ng)
				if !(key in dep_set) {
					dep_set[key] = true
					dep_counts[ng] += 1
					append(&group_deps[ig], ng)
				}
			}
		}
	}

	// BFS topo sort
	order := make([dynamic]int, 0, n_groups, allocator)
	queue := make([dynamic]int, 0, n_groups, allocator)
	for i := 0; i < n_groups; i += 1 {
		if dep_counts[i] == 0 {
			append(&queue, i)
		}
	}
	qi := 0
	for qi < len(queue) {
		g := queue[qi]
		qi += 1
		append(&order, g)
		for succ in group_deps[g] {
			dep_counts[succ] -= 1
			if dep_counts[succ] == 0 {
				append(&queue, succ)
			}
		}
	}

	result.order = make([]int, len(order), allocator)
	copy(result.order, order[:])

	return result
}

// Extract a subgraph for a single kernel group.
// Nodes consuming outputs from OTHER groups become Param nodes in the subgraph.
extract_subgraph :: proc(
	graph: ^Compute_Graph,
	group: ^Kernel_Group,
	node_group_map: ^map[GPU_Node_ID]int,
	allocator: mem.Allocator,
) -> Compute_Graph {
	sub := Compute_Graph{
		nodes     = make([dynamic]GPU_Node, 0, len(group.node_ids), allocator),
		inputs    = make([dynamic]GPU_Node_ID, 0, 4, allocator),
		outputs   = make([dynamic]GPU_Node_ID, 0, 4, allocator),
		func_name = fmt.tprintf("kernel_%d", group.id),
		allocator = allocator,
	}

	// Set of node IDs in this group for quick lookup
	in_group := make(map[GPU_Node_ID]bool, len(group.node_ids), allocator)
	for nid in group.node_ids {
		in_group[nid] = true
	}

	// Map: original node ID → subgraph node ID
	id_map := make(map[GPU_Node_ID]GPU_Node_ID, len(group.node_ids) * 2, allocator)
	// Track external inputs already created as Params
	extern_params := make(map[GPU_Node_ID]GPU_Node_ID, 8, allocator)

	// For each node in the group, add it to the subgraph.
	// Replace references to external nodes with Param nodes.
	for nid in group.node_ids {
		orig := get_node(graph, nid)
		if orig == nil { continue }

		// Remap inputs
		new_inputs := make([]GPU_Node_ID, len(orig.inputs), allocator)
		for inp, i in orig.inputs {
			if inp in in_group {
				// Same group — use remapped ID
				if mapped, ok := id_map[inp]; ok {
					new_inputs[i] = mapped
				} else {
					new_inputs[i] = inp // forward ref, will be fixed
				}
			} else {
				// External — create or reuse Param node
				if param_id, ok := extern_params[inp]; ok {
					new_inputs[i] = param_id
				} else {
					ext_node := get_node(graph, inp)
					param_id := add_node(&sub, GPU_Node{
						kind         = .Param,
						output_type  = ext_node.output_type if ext_node != nil else checker.INVALID_TYPE,
						output_shape = ext_node.output_shape if ext_node != nil else nil,
						name         = fmt.tprintf("ext_%d", int(inp)),
					})
					append(&sub.inputs, param_id)
					extern_params[inp] = param_id
					new_inputs[i] = param_id
				}
			}
		}

		new_id := add_node(&sub, GPU_Node{
			kind         = orig.kind,
			inputs       = new_inputs,
			output_type  = orig.output_type,
			output_shape = orig.output_shape,
			loc          = orig.loc,
			name         = orig.name,
		})
		id_map[nid] = new_id
	}

	// Fix forward references in inputs
	for &node in sub.nodes {
		if node.kind == .Param { continue }
		for i := 0; i < len(node.inputs); i += 1 {
			if mapped, ok := id_map[GPU_Node_ID(node.inputs[i])]; ok {
				if node.inputs[i] != mapped {
					// Check if this was an unmapped group-internal ref
					orig_id := node.inputs[i]
					if orig_id in in_group {
						if m2, ok2 := id_map[orig_id]; ok2 {
							node.inputs[i] = m2
						}
					}
				}
			}
		}
	}

	// Determine outputs: nodes consumed by other groups, or graph outputs
	for nid in group.node_ids {
		// Check if this node is a graph output
		for out in graph.outputs {
			if out == nid {
				if mapped, ok := id_map[nid]; ok {
					append(&sub.outputs, mapped)
				}
			}
		}
		// Check if consumed by a node in another group
		for &other in graph.nodes {
			if other.id in in_group { continue }
			for inp in other.inputs {
				if inp == nid {
					if mapped, ok := id_map[nid]; ok {
						// Avoid duplicates
						already := false
						for existing in sub.outputs {
							if existing == mapped { already = true; break }
						}
						if !already {
							append(&sub.outputs, mapped)
						}
					}
				}
			}
		}
	}

	// Also add original graph's input params that are in this group
	for inp in graph.inputs {
		if inp in in_group {
			if mapped, ok := id_map[inp]; ok {
				append(&sub.inputs, mapped)
			}
		}
	}

	return sub
}

// Print fusion result summary.
print_fusion :: proc(result: ^Fusion_Result) {
	fmt.printfln("  Fusion: %d kernel group(s)", len(result.groups))
	for &group in result.groups {
		kind_str: string
		switch group.dispatch {
		case .Elementwise_1D: kind_str = "elementwise"
		case .MatMul_2D:      kind_str = "matmul"
		case .Reduction:      kind_str = "reduction"
		}
		fmt.printfln("    group %d: %s (%d nodes)", group.id, kind_str, len(group.node_ids))
	}
	fmt.printf("    order: ")
	for idx, i in result.order {
		if i > 0 { fmt.printf(" → ") }
		fmt.printf("%d", idx)
	}
	fmt.println()
}
