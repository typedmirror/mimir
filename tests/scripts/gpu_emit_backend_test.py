#!/usr/bin/env python3
"""
GPU backend emission regression test (S-wave-2, mode-aware 2D-kernel indexing fix).

Bug this guards against: MSL/WGSL emit two mutually-exclusive per-thread
indexing modes for one unfused kernel — 1D elementwise (declares `tid`) and
2D matmul (declares `gid`/`row`/`col`, never `tid`). When an elementwise op
(e.g. a broadcast add) fuses into a 2D matmul kernel, the emitter used to
reference `param_X[tid]` unconditionally — `tid` is UNDECLARED in that mode,
guaranteed invalid MSL/WGSL. Fixed by making `msl_input_ref`/`wgsl_input_ref`
mode-aware (src/gpu/emit_msl.odin, src/gpu/emit_wgsl.odin), backed by a
shared pre-pass (src/gpu/emit.odin: gpu_validate_2d_kernel) that REFUSES
(loud stderr diagnostic + nonzero exit) any pattern it cannot statically
index correctly, rather than silently emitting broken/wrong code — project
invariant: no silent anything.

Covers both directions, permanently:
  a. POSITIVE — tests/gpu/shape_integration.py (single matmul + 1D-broadcast
     add) emits cleanly on msl/wgsl: exit 0, no orphan `tid` reference in a
     kernel that never declares `tid`, and the broadcast is indexed by the
     column coordinate (`param_b[col]` / `param_b[col]`).
  b. NEGATIVE — tests/gpu/training_step.py (two chained matmuls with
     different (K,N) sharing one unfused kernel — a single `dims` uniform
     cannot represent both) refuses on msl/wgsl: nonzero exit, refusal
     diagnostic on stderr, "refused" stated explicitly in the stdout summary
     (never "emitted 0 kernel(s)" with exit 0 — that would be semi-silent
     green).
  c. NEGATIVE — tests/gpu/fusion.py `mixed_dispatch` (matmul fused with a
     Sum reduction — incompatible dispatch-mode combination) refuses the
     same way, on the same guard's other branch.

Usage:
    python3 tests/scripts/gpu_emit_backend_test.py [--mimir-bin ./mimir_bin]
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.join(HERE, "..", "..")
GPU_FIXTURES = os.path.join(REPO_ROOT, "tests", "gpu")

# Declarations that put `tid` legitimately in scope for a given backend.
TID_DECL = {
    "msl": re.compile(r"\bthread_position_in_grid\]\]\s*uint\s+tid\b"),
    "wgsl": re.compile(r"\blet\s+tid\s*="),
}
TID_USE = re.compile(r"\btid\b")


def run_compile_gpu(mimir_bin: str, fixture: str, backend: str, out_dir: str):
    proc = subprocess.run(
        [mimir_bin, "compile-gpu", fixture, "--backend", backend, "--output", out_dir, "-v"],
        capture_output=True, text=True, timeout=30, cwd=REPO_ROOT,
    )
    return proc.stdout, proc.stderr, proc.returncode


def kernel_files(out_dir: str, ext: str):
    if not os.path.isdir(out_dir):
        return []
    return sorted(f for f in os.listdir(out_dir) if f.endswith("." + ext))


def check_no_orphan_tid(path: str, backend: str) -> str | None:
    """Return an error string if `tid` is used without being declared, else None."""
    with open(path) as f:
        content = f.read()
    if TID_USE.search(content) and not TID_DECL[backend].search(content):
        return f"{path}: references `tid` without declaring it (backend={backend})"
    return None


FAILURES = []


def check(label: str, cond: bool, detail: str = ""):
    status = "PASS" if cond else "FAIL"
    print(f"  [{status}] {label}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(label)


def positive_case(mimir_bin: str, backend: str, ext: str, bcast_col_pattern: re.Pattern):
    print(f"positive: shape_integration.py emits cleanly ({backend})")
    with tempfile.TemporaryDirectory(prefix=f"gpu_emit_pos_{backend}_") as out_dir:
        fixture = os.path.join(GPU_FIXTURES, "shape_integration.py")
        stdout, stderr, code = run_compile_gpu(mimir_bin, fixture, backend, out_dir)
        check(f"[{backend}] exit code 0", code == 0, f"exit={code} stderr={stderr!r}")
        check(f"[{backend}] summary states no refusals", "refused" not in stdout, stdout)
        files = kernel_files(out_dir, ext)
        check(f"[{backend}] exactly one kernel file emitted", len(files) == 1, str(files))
        if not files:
            return
        path = os.path.join(out_dir, files[0])
        with open(path) as f:
            content = f.read()
        orphan = check_no_orphan_tid(path, backend)
        check(f"[{backend}] no orphan `tid` reference", orphan is None, orphan or "")
        check(f"[{backend}] broadcast indexed by column coordinate ({bcast_col_pattern.pattern})",
              bool(bcast_col_pattern.search(content)), content)


def negative_case(mimir_bin: str, backend: str, fixture_name: str, must_match: re.Pattern, label: str):
    print(f"negative: {fixture_name} refuses ({backend}) — {label}")
    with tempfile.TemporaryDirectory(prefix=f"gpu_emit_neg_{backend}_") as out_dir:
        fixture = os.path.join(GPU_FIXTURES, fixture_name)
        stdout, stderr, code = run_compile_gpu(mimir_bin, fixture, backend, out_dir)
        check(f"[{backend}] nonzero exit code", code != 0, f"exit={code}")
        check(f"[{backend}] refusal diagnostic on stderr", bool(must_match.search(stderr)), stderr)
        check(f"[{backend}] summary states refusal explicitly ('refused')", "refused" in stdout, stdout)
        check(f"[{backend}] summary never claims silent-green ('emitted 0 kernel(s)' w/ exit 0 is excluded by the exit-code check above)",
              True)


def read_kernel(out_dir: str, name: str, ext: str) -> str:
    path = os.path.join(out_dir, f"{name}.{ext}")
    with open(path) as f:
        return f.read()


def clause_a_reduction_backend_refusal(mimir_bin: str, backend: str):
    """D-G4v2(a): PTX/SPIR-V have no cross-thread reduction primitive — a
    graph containing Sum/Mean/Max/Min/Softmax must refuse loudly on those
    backends rather than emit the old silent single-thread-copy passthrough.
    """
    print(f"negative (clause a): reduction_sizes.py refuses on {backend} (no cross-thread sync)")
    with tempfile.TemporaryDirectory(prefix=f"gpu_emit_clausea_{backend}_") as out_dir:
        fixture = os.path.join(GPU_FIXTURES, "reduction_sizes.py")
        stdout, stderr, code = run_compile_gpu(mimir_bin, fixture, backend, out_dir)
        check(f"[{backend}] nonzero exit code", code != 0, f"exit={code}")
        check(f"[{backend}] refusal names the reduction/softmax gap",
              "reduction/softmax op" in stderr, stderr)
        check(f"[{backend}] summary states refusal explicitly", "refused" in stdout, stdout)


def clause_b_subscript_refusal(mimir_bin: str, backend: str):
    """D-G4v2(b): tensor subscript expressions in @gpu bodies have no
    compute-graph representation — GPU014 must refuse emission (not just
    print a diagnostic while still emitting an incomplete/broken kernel).
    """
    print(f"negative (clause b): subscript_refusal.py refuses on {backend} (GPU014)")
    with tempfile.TemporaryDirectory(prefix=f"gpu_emit_clauseb_{backend}_") as out_dir:
        fixture = os.path.join(GPU_FIXTURES, "subscript_refusal.py")
        stdout, stderr, code = run_compile_gpu(mimir_bin, fixture, backend, out_dir)
        check(f"[{backend}] nonzero exit code", code != 0, f"exit={code}")
        # core.diagnostic_print writes to stdout (unlike the eprintfln-based
        # refusal messages elsewhere in this file, which go to stderr).
        check(f"[{backend}] GPU014 diagnostic fires", "GPU014" in stdout, stdout)
        check(f"[{backend}] summary states refusal explicitly (not a silent 'emitted 1 kernel(s)')",
              "refused" in stdout, stdout)
        check(f"[{backend}] no kernel file written", len(kernel_files(out_dir, "metal" if backend == "msl" else backend)) == 0,
              str(kernel_files(out_dir, "metal" if backend == "msl" else backend)))


def clause_c_saxpy_broadcast(mimir_bin: str, backend: str, ext: str):
    """D-G4v2(c) positive: a length-1 scalar param (`a`) broadcasts as [0];
    the length-N params (`x`, `y`) index as [tid]. The old emitter always
    used [tid], which read out of bounds on a length-1 buffer."""
    print(f"positive (clause c): saxpy_broadcast.py emits cleanly, correct indices ({backend})")
    with tempfile.TemporaryDirectory(prefix=f"gpu_emit_clausec_pos_{backend}_") as out_dir:
        fixture = os.path.join(GPU_FIXTURES, "saxpy_broadcast.py")
        stdout, stderr, code = run_compile_gpu(mimir_bin, fixture, backend, out_dir)
        check(f"[{backend}] exit code 0", code == 0, f"exit={code} stderr={stderr!r}")
        files = kernel_files(out_dir, ext)
        if not files:
            check(f"[{backend}] kernel file emitted", False, "no files")
            return
        content = read_kernel(out_dir, "saxpy", ext)
        check(f"[{backend}] scalar param 'a' indexed [0]", "param_a[0]" in content, content)
        check(f"[{backend}] full-length param 'x' indexed [tid]", "param_x[tid]" in content, content)


def clause_c_broadcast_unsupported(mimir_bin: str, backend: str):
    """D-G4v2(c) negative: a param shape that is neither full-length nor
    scalar has no statically-correct 1D index."""
    print(f"negative (clause c): broadcast_unsupported.py refuses ({backend})")
    with tempfile.TemporaryDirectory(prefix=f"gpu_emit_clausec_neg_{backend}_") as out_dir:
        fixture = os.path.join(GPU_FIXTURES, "broadcast_unsupported.py")
        stdout, stderr, code = run_compile_gpu(mimir_bin, fixture, backend, out_dir)
        check(f"[{backend}] nonzero exit code", code != 0, f"exit={code}")
        check(f"[{backend}] refusal names the broadcast gap",
              "cannot be statically broadcast" in stderr, stderr)
        check(f"[{backend}] summary states refusal explicitly", "refused" in stdout, stdout)


def dg3v2_reduction_sizes_positive(mimir_bin: str, backend: str, ext: str):
    """D-G3v2 + clause (d): real element count, guarded tails, mean divides
    by actual N (not a literal 256), single write to result[0], buffer
    length 1. WGSL additionally: var<workgroup> at module scope, array
    width == workgroup_size (both = GPU_REDUCTION_BLOCK_BOUND)."""
    print(f"positive (D-G3v2/d): reduction_sizes.py emits cleanly, size-general ({backend})")
    with tempfile.TemporaryDirectory(prefix=f"gpu_emit_dg3_{backend}_") as out_dir:
        fixture = os.path.join(GPU_FIXTURES, "reduction_sizes.py")
        stdout, stderr, code = run_compile_gpu(mimir_bin, fixture, backend, out_dir)
        check(f"[{backend}] exit code 0", code == 0, f"exit={code} stderr={stderr!r}")
        if code != 0:
            return
        sum_c = read_kernel(out_dir, "sum_n100", ext)
        check(f"[{backend}] sum_n100 tail-guards at real N=100 (not 256)", "tid < 100u" in sum_c, sum_c)
        check(f"[{backend}] sum_n100 single write to result[0] (tid==0 guard)",
              "tid == 0" in sum_c, sum_c)
        mean_c = read_kernel(out_dir, "mean_n200", ext)
        divisor_ok = ("200" in mean_c.split("sh_")[-1]) if "sh_" in mean_c else ("200" in mean_c)
        check(f"[{backend}] mean_n200 divides by real N=200, not literal 256",
              divisor_ok and "256)" not in mean_c.split("/")[-1][:20], mean_c)
        if backend == "wgsl":
            wg_idx = mean_c.find("var<workgroup>")
            fn_idx = mean_c.find("fn kernel_")
            check("[wgsl] var<workgroup> declared before fn (module scope, not inside body)",
                  wg_idx != -1 and fn_idx != -1 and wg_idx < fn_idx, mean_c)
            check("[wgsl] shared array width matches workgroup_size (256)",
                  "array<f32, 256>" in mean_c and "@workgroup_size(256)" in mean_c, mean_c)


def dg3v2_reduction_oversize_refusal(mimir_bin: str, backend: str):
    """D-G3v2 negative: N > GPU_REDUCTION_BLOCK_BOUND (256) must refuse, not
    silently truncate the reduction to the first 256 elements."""
    print(f"negative (D-G3v2): reduction_oversize.py (N=300) refuses ({backend})")
    with tempfile.TemporaryDirectory(prefix=f"gpu_emit_dg3_neg_{backend}_") as out_dir:
        fixture = os.path.join(GPU_FIXTURES, "reduction_oversize.py")
        stdout, stderr, code = run_compile_gpu(mimir_bin, fixture, backend, out_dir)
        check(f"[{backend}] nonzero exit code", code != 0, f"exit={code}")
        check(f"[{backend}] refusal names the bound", "exceeding the single-workgroup bound" in stderr, stderr)
        check(f"[{backend}] summary states refusal explicitly", "refused" in stdout, stdout)


def clause_e_softmax_barrier(mimir_bin: str, backend: str, ext: str):
    """D-G4v2(e): a barrier must separate every thread's read of the shared
    max (sm[0]) from any thread's overwrite of the same shared array with
    its exp value — without it, a fast thread's write races a slow
    thread's still-pending read."""
    print(f"positive (clause e): reduction_sizes.py softmax_n100 has the race-fix barrier ({backend})")
    with tempfile.TemporaryDirectory(prefix=f"gpu_emit_clausee_{backend}_") as out_dir:
        fixture = os.path.join(GPU_FIXTURES, "reduction_sizes.py")
        stdout, stderr, code = run_compile_gpu(mimir_bin, fixture, backend, out_dir)
        check(f"[{backend}] exit code 0", code == 0, f"exit={code} stderr={stderr!r}")
        if code != 0:
            return
        content = read_kernel(out_dir, "softmax_n100", ext)
        barrier = "threadgroup_barrier(mem_flags::mem_threadgroup)" if backend == "msl" else "workgroupBarrier()"
        # Between reading the max (sm_max_/sm_max_2) and overwriting the
        # shared array with the exp value, there must be a barrier call
        # that is NOT part of the max-reduction tree loop above it.
        max_read_idx = content.find("sm_max_")
        exp_write_idx = content.find("_exp_" if backend == "wgsl" else "sm_exp_", max_read_idx)
        between = content[max_read_idx:exp_write_idx] if max_read_idx != -1 and exp_write_idx != -1 else ""
        check(f"[{backend}] barrier present between max-read and exp-overwrite (data race fix)",
              barrier in between, content)


def clause_f_method_form_activations(mimir_bin: str, backend: str, ext: str):
    """D-G4v2(f)/N2: method-form activation calls extract to their real
    GPU_Op_Kind node, not an empty/opaque node and not a silent passthrough
    of the base tensor — content-checked per op so a regression to
    passthrough (rather than exit-code alone) is caught."""
    print(f"positive (clause f): method_form_activations.py — real op nodes, not passthrough ({backend})")
    with tempfile.TemporaryDirectory(prefix=f"gpu_emit_clausef_{backend}_") as out_dir:
        fixture = os.path.join(GPU_FIXTURES, "method_form_activations.py")
        stdout, stderr, code = run_compile_gpu(mimir_bin, fixture, backend, out_dir)
        check(f"[{backend}] exit code 0", code == 0, f"exit={code} stderr={stderr!r}")
        if code != 0:
            return
        expect = {
            "relu_method": "max(" if backend == "wgsl" else "metal::max(",
            "sigmoid_method": "exp(" if backend == "wgsl" else "metal::exp(",
            "tanh_method": "tanh(",
            "exp_method": "exp(",
            "log_method": "log(",
            "sqrt_method": "sqrt(",
        }
        for fn_name, needle in expect.items():
            content = read_kernel(out_dir, fn_name, ext)
            check(f"[{backend}] {fn_name} emits real op ({needle.strip('(')})", needle in content, content)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mimir-bin", default=os.path.join(REPO_ROOT, "mimir_bin"))
    args = ap.parse_args()
    mimir_bin = os.path.abspath(args.mimir_bin)
    if not os.path.isfile(mimir_bin):
        print(f"mimir binary not found at {mimir_bin}", file=sys.stderr)
        sys.exit(2)

    positive_case(mimir_bin, "msl", "metal", re.compile(r"param_b\[col\]"))
    positive_case(mimir_bin, "wgsl", "wgsl", re.compile(r"param_b\[col\]"))

    negative_case(mimir_bin, "msl", "training_step.py",
                  re.compile(r"chains multiple matmuls with different shapes"), "two-matmul K/N mismatch")
    negative_case(mimir_bin, "wgsl", "training_step.py",
                  re.compile(r"chains multiple matmuls with different shapes"), "two-matmul K/N mismatch")

    negative_case(mimir_bin, "msl", "fusion.py",
                  re.compile(r"mixes matmul .* with 'Sum'"), "matmul+reduction dispatch-mode mix")
    negative_case(mimir_bin, "wgsl", "fusion.py",
                  re.compile(r"mixes matmul .* with 'Sum'"), "matmul+reduction dispatch-mode mix")

    # Phase G Wave 1, L4/candor: D-G3v2 + D-G4v2 clauses (a)-(f).
    clause_a_reduction_backend_refusal(mimir_bin, "ptx")
    clause_a_reduction_backend_refusal(mimir_bin, "spirv")

    clause_b_subscript_refusal(mimir_bin, "msl")
    clause_b_subscript_refusal(mimir_bin, "wgsl")

    clause_c_saxpy_broadcast(mimir_bin, "msl", "metal")
    clause_c_saxpy_broadcast(mimir_bin, "wgsl", "wgsl")
    clause_c_broadcast_unsupported(mimir_bin, "msl")
    clause_c_broadcast_unsupported(mimir_bin, "wgsl")

    dg3v2_reduction_sizes_positive(mimir_bin, "msl", "metal")
    dg3v2_reduction_sizes_positive(mimir_bin, "wgsl", "wgsl")
    dg3v2_reduction_oversize_refusal(mimir_bin, "msl")
    dg3v2_reduction_oversize_refusal(mimir_bin, "wgsl")

    clause_e_softmax_barrier(mimir_bin, "msl", "metal")
    clause_e_softmax_barrier(mimir_bin, "wgsl", "wgsl")

    clause_f_method_form_activations(mimir_bin, "msl", "metal")
    clause_f_method_form_activations(mimir_bin, "wgsl", "wgsl")

    print()
    if FAILURES:
        print(f"FAIL: {len(FAILURES)} check(s) failed:")
        for f in FAILURES:
            print(f"  - {f}")
        sys.exit(1)
    print("PASS: all gpu_emit_backend checks green")
    sys.exit(0)


if __name__ == "__main__":
    main()
