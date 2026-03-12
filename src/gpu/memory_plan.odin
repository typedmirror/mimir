package gpu

import "core:mem"
import "core:fmt"

// Memory Planning — compute buffer sizes, analyze liveness, plan buffer reuse.

Buffer_Alloc :: struct {
	node_id:   GPU_Node_ID,
	byte_size: int, // shape_product * element_bytes (-1 if symbolic)
	offset:    int, // byte offset in total allocation
	first_use: int, // group index where first written
	last_use:  int, // group index where last read
	is_input:  bool,
	is_output: bool,
}

Memory_Plan :: struct {
	buffers:            [dynamic]Buffer_Alloc,
	total_bytes:        int,
	peak_bytes:         int,
	input_bytes:        int,
	output_bytes:       int,
	intermediate_bytes: int,
	reuse_savings:      int,
	allocator:          mem.Allocator,
}

// Plan memory for a compute graph, optionally with fusion groups.
// If fusion is nil, treats the entire graph as one group.
plan_memory :: proc(
	graph: ^Compute_Graph,
	fusion: ^Fusion_Result,
	type_ctx: ^GPU_Type_Context,
	allocator: mem.Allocator,
) -> Memory_Plan {
	plan := Memory_Plan{
		buffers   = make([dynamic]Buffer_Alloc, 0, len(graph.nodes), allocator),
		allocator = allocator,
	}

	// Build node → group index map
	node_group := make(map[GPU_Node_ID]int, len(graph.nodes), allocator)
	if fusion != nil && len(fusion.groups) > 0 {
		for &group in fusion.groups {
			for nid in group.node_ids {
				node_group[nid] = group.id
			}
		}
	} else {
		// Single group: all nodes in group 0
		for &node in graph.nodes {
			node_group[node.id] = 0
		}
	}

	// Input/output sets
	input_set := make(map[GPU_Node_ID]bool, len(graph.inputs), allocator)
	for inp in graph.inputs { input_set[inp] = true }
	output_set := make(map[GPU_Node_ID]bool, len(graph.outputs), allocator)
	for out in graph.outputs { output_set[out] = true }

	// Step 1: Size each node's output buffer
	// Step 2: Compute liveness [first_use, last_use]
	for &node in graph.nodes {
		if node.kind == .Constant { continue } // no buffer needed

		elem_bytes := element_byte_size(node.output_type, type_ctx)
		byte_size := shape_byte_size(node.output_shape, elem_bytes)

		// Liveness: first_use = group where this node is defined
		first_use := 0
		if g, ok := node_group[node.id]; ok {
			first_use = g
		}

		// last_use = max group index of all consumers
		last_use := first_use
		for &other in graph.nodes {
			for inp in other.inputs {
				if inp == node.id {
					if g, ok := node_group[other.id]; ok {
						if g > last_use { last_use = g }
					}
				}
			}
		}
		// Outputs are live until the end
		if node.id in output_set {
			n_groups := 1
			if fusion != nil { n_groups = len(fusion.groups) }
			last_use = n_groups - 1
		}

		append(&plan.buffers, Buffer_Alloc{
			node_id   = node.id,
			byte_size = byte_size,
			offset    = -1, // not yet allocated
			first_use = first_use,
			last_use  = last_use,
			is_input  = node.id in input_set,
			is_output = node.id in output_set,
		})
	}

	// Step 3: Greedy interval-coloring allocation
	// Sort buffers by size descending (largest first gets best reuse)
	sort_buffers_by_size(&plan.buffers)

	// Track allocated slots: (offset, size, last_use)
	Alloc_Slot :: struct {
		offset:   int,
		size:     int,
		last_use: int,
	}
	slots := make([dynamic]Alloc_Slot, 0, len(plan.buffers), allocator)
	next_offset := 0

	for &buf in plan.buffers {
		if buf.byte_size <= 0 { continue } // symbolic or zero

		// Input/output buffers can't reuse
		if buf.is_input || buf.is_output {
			buf.offset = next_offset
			next_offset += buf.byte_size
			append(&slots, Alloc_Slot{
				offset   = buf.offset,
				size     = buf.byte_size,
				last_use = buf.last_use,
			})
			continue
		}

		// Try to find a reusable slot: expired, sufficient size
		best_idx := -1
		best_waste := max(int)
		for &slot, i in slots {
			if slot.last_use < buf.first_use && slot.size >= buf.byte_size {
				waste := slot.size - buf.byte_size
				if waste < best_waste {
					best_waste = waste
					best_idx = i
				}
			}
		}

		if best_idx >= 0 {
			buf.offset = slots[best_idx].offset
			slots[best_idx].last_use = buf.last_use
			plan.reuse_savings += buf.byte_size
		} else {
			buf.offset = next_offset
			next_offset += buf.byte_size
			append(&slots, Alloc_Slot{
				offset   = buf.offset,
				size     = buf.byte_size,
				last_use = buf.last_use,
			})
		}
	}

	// Step 4: Compute totals
	plan.total_bytes = next_offset
	for &buf in plan.buffers {
		if buf.byte_size <= 0 { continue }
		if buf.is_input {
			plan.input_bytes += buf.byte_size
		} else if buf.is_output {
			plan.output_bytes += buf.byte_size
		} else {
			plan.intermediate_bytes += buf.byte_size
		}
	}

	// Peak: max bytes live at any group boundary
	n_groups := 1
	if fusion != nil && len(fusion.groups) > 0 { n_groups = len(fusion.groups) }
	for g := 0; g < n_groups; g += 1 {
		live_bytes := 0
		for &buf in plan.buffers {
			if buf.byte_size <= 0 { continue }
			if buf.first_use <= g && buf.last_use >= g {
				live_bytes += buf.byte_size
			}
		}
		if live_bytes > plan.peak_bytes {
			plan.peak_bytes = live_bytes
		}
	}

	return plan
}

// Print a human-readable memory plan.
print_memory_plan :: proc(plan: ^Memory_Plan) {
	fmt.printfln("  Memory Plan:")
	fmt.printfln("    total:        %s", format_bytes(plan.total_bytes))
	fmt.printfln("    peak live:    %s", format_bytes(plan.peak_bytes))
	fmt.printfln("    inputs:       %s", format_bytes(plan.input_bytes))
	fmt.printfln("    outputs:      %s", format_bytes(plan.output_bytes))
	fmt.printfln("    intermediate: %s", format_bytes(plan.intermediate_bytes))
	if plan.reuse_savings > 0 {
		fmt.printfln("    reuse saved:  %s", format_bytes(plan.reuse_savings))
	}
	fmt.printfln("    buffers: %d", len(plan.buffers))
	for &buf in plan.buffers {
		kind := "intermediate"
		if buf.is_input { kind = "input" }
		else if buf.is_output { kind = "output" }
		if buf.byte_size > 0 {
			fmt.printfln("      node %d: %s @ offset %d, live [%d..%d] (%s)",
				int(buf.node_id), format_bytes(buf.byte_size), buf.offset,
				buf.first_use, buf.last_use, kind)
		} else {
			fmt.printfln("      node %d: symbolic size, live [%d..%d] (%s)",
				int(buf.node_id), buf.first_use, buf.last_use, kind)
		}
	}
}

// Simple insertion sort for buffers by byte_size descending.
sort_buffers_by_size :: proc(buffers: ^[dynamic]Buffer_Alloc) {
	for i := 1; i < len(buffers); i += 1 {
		key := buffers[i]
		j := i - 1
		for j >= 0 && buffers[j].byte_size < key.byte_size {
			buffers[j + 1] = buffers[j]
			j -= 1
		}
		buffers[j + 1] = key
	}
}

// Format bytes into human-readable string.
format_bytes :: proc(bytes: int) -> string {
	if bytes < 0 { return "unknown" }
	if bytes < 1024 { return fmt.tprintf("%d B", bytes) }
	if bytes < 1024 * 1024 { return fmt.tprintf("%.1f KB", f64(bytes) / 1024.0) }
	return fmt.tprintf("%.1f MB", f64(bytes) / (1024.0 * 1024.0))
}
