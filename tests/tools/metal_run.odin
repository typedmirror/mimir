package main

// Metal execution leg of the GPU kernel parity harness (D-G2v2,
// docs/FACTORY_CONTRACT_G.md, lane L2 "scale"). Standalone test binary — NOT
// a mimir command (the no-new-commands ban does not apply to test
// infrastructure).
//
// Two modes:
//
//   (no args) — Stage-0 self-test: hardcoded MSL vector-add kernel, compiled
//   AT RUNTIME via newLibraryWithSource (no Xcode / `metal` CLI needed —
//   this machine is CLT-only), dispatched, read back, and checked against a
//   CPU reference. This is the spike that gated the lane; kept as a standing
//   regression check (`metal_run_bin` with no args).
//
//   `run <kernel.metal> <entry> <dispatch> <buffer-spec>...` — Stage-1
//   general driver, invoked by tests/scripts/kernel_parity_test.py per zoo
//   entry. Loads a real compile-gpu-emitted .metal file, dispatches it, and
//   prints raw output-buffer contents to stdout for the Python harness to
//   compare against its own CPU reference — this tool does NOT judge
//   numeric correctness itself in `run` mode, only whether the Metal API
//   call sequence itself succeeded (compiled, bound, dispatched cleanly).
//
//     dispatch  := "1d:<N>"                 -- elementwise-style;
//                                               dispatchThreads({N,1,1}, {min(N,256),1,1})
//                | "reduce"                 -- reduction/softmax-style
//                                               (seam-1 ABI, D-G3v2/D-G4v2(e)):
//                                               PARSES the emitted kernel's
//                                               own "exactly 1 threadgroup of
//                                               N threads" comment and
//                                               dispatches exactly that many
//                                               threads in exactly one
//                                               threadgroup — no size is
//                                               taken from the CLI, no width
//                                               is assumed; missing the
//                                               marker comment is a loud
//                                               refusal (see
//                                               parse_dispatch_requirement).
//                | "2d:<M>:<K>:<N>"          -- matmul-style; binds a
//                                               `constant uint3&` dims uniform
//                                               {M,K,N} (12 bytes, mirrors
//                                               src/gpu/host_runtime.odin's
//                                               own `new Uint32Array([dims.M,
//                                               dims.K, dims.N])`, size 12)
//                                               at the buffer index right
//                                               after the last data buffer;
//                                               dispatchThreads({M,N,1},
//                                               {8,8,1}) — X~M, Y~N.
//
//                                               NOTE (D-G2v2 ruling, lead,
//                                               2026-08-19): this is
//                                               DELIBERATELY NOT what
//                                               src/gpu/host_runtime.odin:148
//                                               does. host_runtime.odin's own
//                                               `--host` WebGPU JS glue
//                                               dispatches
//                                               `dispatchWorkgroups(ceil(N/8),
//                                               ceil(M/8))` (X~N, Y~M), which
//                                               is TRANSPOSED relative to the
//                                               emitted kernel's own
//                                               `row = gid.x; col = gid.y`
//                                               binding (emit_msl.odin:58-59,
//                                               emit_wgsl.odin:51-52,
//                                               identical in both backends).
//                                               Empirically confirmed on a
//                                               real device (Apple M3, real
//                                               compiled kernel_linear_forward
//                                               .metal, M=3/K=2/N=4 row/col-
//                                               sensitive case): the
//                                               host-mirrored order silently
//                                               zero-fills the last column
//                                               (and risks OOB writes past the
//                                               M×N result buffer whenever
//                                               N>M); X~M,Y~N matches the CPU
//                                               reference exactly. This is a
//                                               real bug in host_runtime.odin
//                                               (out of this lane's scope —
//                                               lead owns the fix at wave
//                                               close). This tool dispatches
//                                               the geometry the KERNEL
//                                               actually needs, so parity
//                                               measures kernel correctness,
//                                               not host_runtime.odin's glue.
//     buffer-spec (repeated, positional == buffer index order):
//                 := "in:<path>"             -- read raw f32 LE from file
//                  | "out:<count>"           -- zero-init f32 buffer, dumped
//                                               after dispatch
//
//   Every Metal-API failure path (nil device, compile error, nil function/
//   pipeline/buffer/queue/encoder, command-buffer .Error status) is loud: a
//   stderr diagnostic + nonzero exit — never silent, per the project's
//   no-silent-anything invariant. `run` mode's exit code reflects ONLY
//   whether the dispatch itself succeeded, never numeric correctness.
//   Exit codes: 0 = dispatch ok, 1 = dispatch/API failure (REFUSED), 2 = no
//   Metal-capable device present (SKIPPED(no-GPU) — distinct from 1 so the
//   Python harness never conflates "no GPU here" with a real failure).
//
// Build (single-file, not part of the mimir binary):
//   odin build tests/tools/metal_run.odin -file -out:tests/tools/metal_run_bin
// Run:
//   ./tests/tools/metal_run_bin                          (self-test)
//   ./tests/tools/metal_run_bin run k.metal kernel_foo 1d:64 in:a.bin in:b.bin out:64
//   ./tests/tools/metal_run_bin run k.metal kernel_foo 2d:32:784:128 in:x.bin in:w.bin in:b.bin out:4096

import MTL "vendor:darwin/Metal"
import NS "core:sys/darwin/Foundation"
import "core:fmt"
import "core:os"
import "core:math"
import "core:strings"
import "core:strconv"

ABS_TOL :: 1e-5

fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprintf("RED: ")
	fmt.eprintfln(format, ..args)
	fmt.println("RESULT: RED — round-trip did not produce correct values (see stderr)")
	os.exit(1)
}

// `run`-mode failures: the dispatch itself (not correctness) failed.
run_fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprintf("REFUSED: ")
	fmt.eprintfln(format, ..args)
	fmt.println("RESULT: REFUSED — dispatch did not complete cleanly (see stderr)")
	os.exit(1)
}

// No Metal-capable device present. Distinct exit code (2) and distinct
// stdout marker from run_fail/fail (exit 1) — this is a SKIPPED condition,
// never a FAIL: tests/scripts/kernel_parity_test.py greps for this marker
// so the parity table renders SKIPPED(no-GPU), never blank, never PASS, and
// never conflated with a real dispatch/correctness failure (D-G2v2 m2).
no_gpu_skip :: proc() -> ! {
	fmt.eprintln("no Metal-capable device found (MTLCreateSystemDefaultDevice returned nil)")
	fmt.println("RESULT: SKIPPED(no-GPU)")
	os.exit(2)
}

main :: proc() {
	args := os.args
	if len(args) >= 2 && args[1] == "run" {
		run_mode(args[2:])
		return
	}
	self_test()
}

// ==================== Stage-0 self-test (unchanged behavior) ====================

VECTOR_ADD_MSL :: `
#include <metal_stdlib>
using namespace metal;

kernel void vector_add(
    device const float* a [[buffer(0)]],
    device const float* b [[buffer(1)]],
    device float* result [[buffer(2)]],
    uint tid [[thread_position_in_grid]])
{
    result[tid] = a[tid] + b[tid];
}
`

self_test :: proc() {
	N :: 8

	device := MTL.CreateSystemDefaultDevice()
	if device == nil {
		no_gpu_skip()
	}
	// No defer release() calls in this tool: main always terminates via
	// os.exit (success or RED), which never runs deferred statements —
	// the OS reclaims all resources on process exit regardless.

	device_name := device->name()->odinString()
	fmt.printfln("device: %s", device_name)

	source := NS.AT(VECTOR_ADD_MSL)
	library, lib_err := device->newLibraryWithSource(source, nil)
	if lib_err != nil {
		fail("MSL compile failed: %s", lib_err->localizedDescription()->odinString())
	}

	function := library->newFunctionWithName(NS.AT("vector_add"))
	if function == nil {
		fail("newFunctionWithName(\"vector_add\") returned nil — function not found in compiled library")
	}

	pipeline, pipe_err := device->newComputePipelineState(function)
	if pipe_err != nil {
		fail("newComputePipelineState failed: %s", pipe_err->localizedDescription()->odinString())
	}

	a := [N]f32{1, 2, 3, 4, 5, 6, 7, 8}
	b := [N]f32{10, 20, 30, 40, 50, 60, 70, 80}
	expected: [N]f32
	for i in 0 ..< N {
		expected[i] = a[i] + b[i]
	}

	buf_a := device->newBuffer(a[:], MTL.ResourceOptions{})
	if buf_a == nil {
		fail("newBuffer(a) returned nil")
	}

	buf_b := device->newBuffer(b[:], MTL.ResourceOptions{})
	if buf_b == nil {
		fail("newBuffer(b) returned nil")
	}

	buf_result := device->newBuffer(NS.UInteger(N * size_of(f32)), MTL.ResourceOptions{})
	if buf_result == nil {
		fail("newBuffer(result) returned nil")
	}

	queue := device->newCommandQueue()
	if queue == nil {
		fail("newCommandQueue returned nil")
	}

	cmd_buf := queue->commandBuffer()
	if cmd_buf == nil {
		fail("commandBuffer returned nil")
	}

	encoder := cmd_buf->computeCommandEncoder()
	if encoder == nil {
		fail("computeCommandEncoder returned nil")
	}
	encoder->setComputePipelineState(pipeline)
	encoder->setBuffer(buf_a, 0, 0)
	encoder->setBuffer(buf_b, 0, 1)
	encoder->setBuffer(buf_result, 0, 2)
	encoder->dispatchThreads(MTL.Size{N, 1, 1}, MTL.Size{N, 1, 1})
	encoder->endEncoding()

	cmd_buf->commit()
	cmd_buf->waitUntilCompleted()

	if status := cmd_buf->status(); status == .Error {
		err := cmd_buf->error()
		if err != nil {
			fail("command buffer execution failed: %s", err->localizedDescription()->odinString())
		}
		fail("command buffer execution failed (status .Error, no NSError attached)")
	}

	result_bytes := buf_result->contents()
	if len(result_bytes) < N * size_of(f32) {
		fail("result buffer contents too short: got %d bytes, want %d", len(result_bytes), N * size_of(f32))
	}
	result := (^[N]f32)(raw_data(result_bytes))^

	all_ok := true
	for i in 0 ..< N {
		delta := math.abs(result[i] - expected[i])
		if delta > ABS_TOL {
			fmt.eprintfln("  [%d] expected=%f actual=%f delta=%f (> tol %f)", i, expected[i], result[i], delta, ABS_TOL)
			all_ok = false
		}
	}

	fmt.printfln("expected: %v", expected)
	fmt.printfln("actual:   %v", result)

	if !all_ok {
		fail("one or more elements exceeded abs tol %f", ABS_TOL)
	}

	fmt.println("RESULT: PASS — vector-add round-trip correct on device above")
	os.exit(0)
}

// ==================== Stage-1 general driver (`run` mode) ====================

Buffer_Spec :: struct {
	is_input: bool,
	path:     string, // for in:
	count:    int,    // element count (in: from file size/4; out: from spec)
}

// Parses the emitter's own dispatch-requirement comment, e.g.:
//   "// dispatch requirement: exactly 1 threadgroup of 256 threads"
// out of a raw kernel source string. Returns (thread_count, true) on a
// match, (0, false) if the marker text isn't present at all — callers must
// treat that as a loud refusal, never a silent default.
parse_dispatch_requirement :: proc(src: string) -> (threads: int, ok: bool) {
	marker :: "exactly 1 threadgroup of "
	idx := strings.index(src, marker)
	if idx < 0 {
		return 0, false
	}
	rest := src[idx + len(marker):]
	end := strings.index(rest, " threads")
	if end < 0 {
		return 0, false
	}
	n, pok := strconv.parse_int(rest[:end])
	if !pok || n <= 0 {
		return 0, false
	}
	return n, true
}

run_mode :: proc(argv: []string) {
	if len(argv) < 3 {
		run_fail("usage: metal_run_bin run <kernel.metal> <entry> <dispatch> <buffer-spec>...")
	}
	kernel_path := argv[0]
	entry_name := argv[1]
	dispatch_spec := argv[2]
	buffer_args := argv[3:]

	if len(buffer_args) == 0 {
		run_fail("at least one buffer-spec required (in:<path> or out:<count>)")
	}

	specs := make([dynamic]Buffer_Spec)
	for tok in buffer_args {
		if strings.has_prefix(tok, "in:") {
			path := tok[3:]
			data, rerr := os.read_entire_file(path, context.allocator)
			if rerr != nil {
				run_fail("cannot read input file %q: %v", path, rerr)
			}
			if len(data) % size_of(f32) != 0 {
				run_fail("input file %q size %d not a multiple of 4 bytes (f32)", path, len(data))
			}
			append(&specs, Buffer_Spec{is_input = true, path = path, count = len(data) / size_of(f32)})
		} else if strings.has_prefix(tok, "out:") {
			count, ok := strconv.parse_int(tok[4:])
			if !ok || count <= 0 {
				run_fail("bad out: spec %q — want out:<positive-int-count>", tok)
			}
			append(&specs, Buffer_Spec{is_input = false, count = count})
		} else {
			run_fail("bad buffer-spec %q — want in:<path> or out:<count>", tok)
		}
	}

	kernel_src, kerr := os.read_entire_file(kernel_path, context.allocator)
	if kerr != nil {
		run_fail("cannot read kernel file %q: %v", kernel_path, kerr)
	}

	device := MTL.CreateSystemDefaultDevice()
	if device == nil {
		no_gpu_skip()
	}
	device_name := device->name()->odinString()
	fmt.printfln("DEVICE %s", device_name)

	src_str := NS.String.alloc()->initWithOdinString(string(kernel_src))
	library, lib_err := device->newLibraryWithSource(src_str, nil)
	if lib_err != nil {
		run_fail("MSL compile failed (%s): %s", kernel_path, lib_err->localizedDescription()->odinString())
	}

	function := library->newFunctionWithName(NS.String.alloc()->initWithOdinString(entry_name))
	if function == nil {
		run_fail("newFunctionWithName(%q) returned nil — entry not found in %s", entry_name, kernel_path)
	}

	pipeline, pipe_err := device->newComputePipelineState(function)
	if pipe_err != nil {
		run_fail("newComputePipelineState failed: %s", pipe_err->localizedDescription()->odinString())
	}

	// Build data buffers (in: and out:, in CLI order == buffer index order).
	mtl_buffers := make([dynamic]^MTL.Buffer)
	for spec, idx in specs {
		if spec.is_input {
			data, rerr := os.read_entire_file(spec.path, context.allocator)
			if rerr != nil {
				run_fail("cannot re-read input file %q: %v", spec.path, rerr)
			}
			buf := device->newBuffer(data, MTL.ResourceOptions{})
			if buf == nil {
				run_fail("newBuffer failed for input %q (index %d)", spec.path, idx)
			}
			append(&mtl_buffers, buf)
		} else {
			buf := device->newBuffer(NS.UInteger(spec.count * size_of(f32)), MTL.ResourceOptions{})
			if buf == nil {
				run_fail("newBuffer failed for output (index %d, count %d)", idx, spec.count)
			}
			append(&mtl_buffers, buf)
		}
	}

	// Parse dispatch spec and (for 2D) build + append the dims uniform buffer
	// as the LAST buffer, immediately after all data buffers — matching the
	// compile-gpu emission convention observed in generated .metal files
	// (`constant uint3& dims [[buffer(N)]]` where N == number of data
	// buffers, i.e. right after `result`).
	threads_per_grid: MTL.Size
	threads_per_threadgroup: MTL.Size

	if strings.has_prefix(dispatch_spec, "1d:") {
		n, ok := strconv.parse_int(dispatch_spec[3:])
		if !ok || n <= 0 {
			run_fail("bad 1d dispatch spec %q", dispatch_spec)
		}
		tg := n < 256 ? n : 256
		threads_per_grid = MTL.Size{NS.Integer(n), 1, 1}
		threads_per_threadgroup = MTL.Size{NS.Integer(tg), 1, 1}
	} else if strings.has_prefix(dispatch_spec, "2d:") {
		parts := strings.split(dispatch_spec[3:], ":")
		if len(parts) != 3 {
			run_fail("bad 2d dispatch spec %q — want 2d:M:K:N", dispatch_spec)
		}
		m, ok_m := strconv.parse_int(parts[0])
		k, ok_k := strconv.parse_int(parts[1])
		n, ok_n := strconv.parse_int(parts[2])
		if !ok_m || !ok_k || !ok_n || m <= 0 || k <= 0 || n <= 0 {
			run_fail("bad 2d dispatch dims in %q", dispatch_spec)
		}
		dims := [3]u32{u32(m), u32(k), u32(n)}
		dims_buf := device->newBuffer(dims[:], MTL.ResourceOptions{})
		if dims_buf == nil {
			run_fail("newBuffer failed for dims uniform {M=%d,K=%d,N=%d}", m, k, n)
		}
		append(&mtl_buffers, dims_buf)
		// D-G2v2 ruling (lead, 2026-08-19): X~M, Y~N — matches the kernel's
		// own `row = gid.x; col = gid.y` binding. NOT host_runtime.odin:148's
		// order (that's transposed — see file header comment for the
		// empirical repro and disposition).
		threads_per_grid = MTL.Size{NS.Integer(m), NS.Integer(n), 1}
		threads_per_threadgroup = MTL.Size{8, 8, 1}
	} else if dispatch_spec == "reduce" {
		// Reduction/softmax kernels (seam-1 ABI, D-G3v2/D-G4v2(e), candor):
		// require EXACTLY one threadgroup dispatched, whatever its width —
		// the shared-memory tree (threadgroup float sh_N[W]) is sized to
		// that width and every lane 0..W-1 must run (tail lanes beyond the
		// real N are guarded in-kernel with an identity value: 0 for sum,
		// +-INFINITY for max/min, -INFINITY for softmax's max-pass). Under-
		// dispatching (e.g. only N threads when N < W) leaves shared-memory
		// slots N..W-1 uninitialized garbage — silently wrong, not a crash.
		// The emitter states its own requirement in a source comment; this
		// tool PARSES it rather than assuming a width, so it stays correct
		// if the emitted block width ever changes.
		threads, ok := parse_dispatch_requirement(string(kernel_src))
		if !ok {
			run_fail("dispatch spec \"reduce\" requires a dispatch-requirement comment " +
				"(\"exactly 1 threadgroup of N threads\") in %s — none found; refusing to " +
				"guess a threadgroup width", kernel_path)
		}
		threads_per_grid = MTL.Size{NS.Integer(threads), 1, 1}
		threads_per_threadgroup = MTL.Size{NS.Integer(threads), 1, 1}
	} else {
		run_fail("bad dispatch spec %q — want 1d:<N>, 2d:M:K:N, or reduce", dispatch_spec)
	}

	queue := device->newCommandQueue()
	if queue == nil {
		run_fail("newCommandQueue returned nil")
	}
	cmd_buf := queue->commandBuffer()
	if cmd_buf == nil {
		run_fail("commandBuffer returned nil")
	}
	encoder := cmd_buf->computeCommandEncoder()
	if encoder == nil {
		run_fail("computeCommandEncoder returned nil")
	}
	encoder->setComputePipelineState(pipeline)
	for buf, idx in mtl_buffers {
		encoder->setBuffer(buf, 0, NS.UInteger(idx))
	}
	encoder->dispatchThreads(threads_per_grid, threads_per_threadgroup)
	encoder->endEncoding()

	cmd_buf->commit()
	cmd_buf->waitUntilCompleted()

	if status := cmd_buf->status(); status == .Error {
		err := cmd_buf->error()
		if err != nil {
			run_fail("command buffer execution failed: %s", err->localizedDescription()->odinString())
		}
		run_fail("command buffer execution failed (status .Error, no NSError attached)")
	}

	// Dump every `out:` buffer's contents, in CLI order.
	for spec, idx in specs {
		if spec.is_input {
			continue
		}
		buf := mtl_buffers[idx]
		result_bytes := buf->contents()
		want_bytes := spec.count * size_of(f32)
		if len(result_bytes) < want_bytes {
			run_fail("output buffer (index %d) contents too short: got %d bytes, want %d", idx, len(result_bytes), want_bytes)
		}
		floats := (^f32)(raw_data(result_bytes))
		floats_slice := (cast([^]f32)floats)[:spec.count]
		sb := strings.builder_make()
		fmt.sbprintf(&sb, "OUT %d %d", idx, spec.count)
		for v in floats_slice {
			fmt.sbprintf(&sb, " %v", v)
		}
		fmt.println(strings.to_string(sb))
	}

	fmt.println("RESULT: DISPATCH-OK")
	os.exit(0)
}
