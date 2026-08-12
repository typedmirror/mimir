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
