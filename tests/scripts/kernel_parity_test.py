#!/usr/bin/env python3
"""
GPU kernel parity test — Stage 1 of D-G2v2 (docs/FACTORY_CONTRACT_G.md, lane
L2 "scale"), the wave's device-execution corroboration leg.

Per zoo/ entry: run the entry's real @gpu function directly under the pure-
Python runtime shim (python/mimir/array.py) with the entry's own documented
seeded inputs (zeros()/ones(), per zoo/README.md's runnable-leg convention —
menagerie/L3's canon, consumed here rather than reinvented) to get a
reference output. Separately, compile-gpu the SAME entry to MSL and execute
the emitted kernel on a real Metal device via tests/tools/metal_run_bin
(built from tests/tools/metal_run.odin). Compare device output against the
shim reference elementwise.

This is NOT re-deriving the shim's own math independently — that's
shim_functional_test.py's job (is the shim's arithmetic right in the first
place, checked against a from-scratch nested-loop reference). This test's
job is different: does the real Metal device compute the SAME thing the
shim says it should, for the ACTUAL compiled kernel — a hardware-vs-software
cross-check using two independent execution engines (CPU/Python interpreter
vs GPU/Metal compute pipeline) evaluating the same formula.

2D dispatch geometry: X~M, Y~N (matches the emitted kernel's own
`row = gid.x; col = gid.y` binding, both backends — emit_msl.odin:58-59,
emit_wgsl.odin:51-52). This is DELIBERATELY NOT src/gpu/host_runtime.odin
:148's dispatch order (`dispatchWorkgroups(ceil(N/8), ceil(M/8))`, X~N,Y~M):
that order was found, empirically, on real Metal hardware, to be transposed
relative to the kernel's row/col binding — it silently zero-fills output
columns and risks OOB writes past the M x N result buffer whenever M != N.
Ruled by lead 2026-08-19 (D-G2v2 ruling (a)): parity dispatches the geometry
the KERNEL actually needs, so parity measures kernel correctness, not
host_runtime.odin's separate `--host` glue bug (that bug is a lead action
at wave close, out of this lane's scope — see tests/tools/metal_run.odin's
file header and docs/DECISIONS.md for the repro).

SKIPPED(no-GPU): metal_run_bin exits 2 with `RESULT: SKIPPED(no-GPU)` on
stdout when no Metal-capable device is present. This script renders that
condition as SKIPPED(no-GPU) in the table — never blank, never PASS, and
never counted as a FAIL — per D-G2v2 m2 ("assume nothing" about CI runner
GPU availability). Locally (real hardware), a SKIPPED row is unexpected and
worth investigating; in CI it is the expected outcome on today's runners.

Deliberately-broken-kernel FAIL proof (--mutation-check): compiles
vector_add, flips the emitted MSL's `+` to `-`, re-dispatches, and asserts
the comparison reports FAIL (not a silent PASS) — this is part of L2's
BEFORE-DONE acceptance, not optional.

Usage:
    python3 tests/scripts/kernel_parity_test.py
    python3 tests/scripts/kernel_parity_test.py --mutation-check
    ZOO_DIR=/path/to/zoo python3 tests/scripts/kernel_parity_test.py
    MIMIR_BIN=./mimir_bin METAL_RUN_BIN=./tests/tools/metal_run_bin python3 tests/scripts/kernel_parity_test.py
"""

import argparse
import importlib.util
import os
import re
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.join(HERE, "..", "..")
ZOO_DIR = os.environ.get("ZOO_DIR", os.path.join(REPO_ROOT, "zoo"))
MIMIR_BIN = os.environ.get("MIMIR_BIN", os.path.join(REPO_ROOT, "mimir_bin"))
METAL_RUN_BIN = os.environ.get(
    "METAL_RUN_BIN", os.path.join(REPO_ROOT, "tests", "tools", "metal_run_bin")
)

sys.path.insert(0, os.path.join(REPO_ROOT, "python"))
from mimir.array import ones, zeros  # noqa: E402 - sys.path must be set first

GEN = {"ones": ones, "zeros": zeros}


def numel(shape):
    n = 1
    for s in shape:
        n *= s
    return n


# ---- Tier-1 entry table -------------------------------------------------
# Mirrors zoo/{vector_add,squared_error,linear_forward,matmul}.py exactly
# (function names, shapes, seeded-input generators) as authored by L3
# "menagerie". All four are elementwise or matmul (no reductions in Tier 1),
# so all use a flat absolute tolerance per D-G2v2 ("elementwise/matmul: abs
# tol 1e-5"). The relative-tolerance-derived form D-G2v2 specifies for
# reductions/softmax is Tier-2 territory (gated on D-G3v2 + D-G4v2), not
# built here — tol_kind is scaffolding for when Tier 2 lands.
ENTRIES = [
    {
        "name": "vector_add",
        "file": "vector_add.py",
        "func": "vector_add",
        "inputs": [("x", (1024,), "ones"), ("y", (1024,), "ones")],
        "output_shape": (1024,),
        "dispatch": ("1d", 1024),
        "tol_kind": "abs",
        "tol": 1e-5,
    },
    {
        "name": "squared_error",
        "file": "squared_error.py",
        "func": "squared_error",
        "inputs": [("pred", (512,), "ones"), ("target", (512,), "zeros")],
        "output_shape": (512,),
        "dispatch": ("1d", 512),
        "tol_kind": "abs",
        "tol": 1e-5,
    },
    {
        "name": "linear_forward",
        "file": "linear_forward.py",
        "func": "linear_forward",
        "inputs": [("x", (16, 64), "ones"), ("w", (64, 32), "ones"), ("b", (32,), "ones")],
        "output_shape": (16, 32),
        "dispatch": ("2d", 16, 64, 32),
        "tol_kind": "abs",
        "tol": 1e-5,
    },
    {
        "name": "matmul",
        "file": "matmul.py",
        "func": "matmul",
        "inputs": [("a", (8, 16), "ones"), ("b", (16, 32), "ones")],
        "output_shape": (8, 32),
        "dispatch": ("2d", 8, 16, 32),
        "tol_kind": "abs",
        "tol": 1e-5,
    },
]


def load_module(path, modname):
    spec = importlib.util.spec_from_file_location(modname, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def shim_reference(entry):
    """Run the real @gpu function under the pure-Python shim with the
    entry's documented seeded inputs. Returns (input_tensors, output_flat)."""
    path = os.path.join(ZOO_DIR, entry["file"])
    mod = load_module(path, entry["name"] + "_zoomod")
    func = getattr(mod, entry["func"])
    tensors = [GEN[gen](*shape) for _name, shape, gen in entry["inputs"]]
    out = func(*tensors)
    return tensors, list(out.data)


def compile_kernel(entry, out_dir):
    src = os.path.join(ZOO_DIR, entry["file"])
    proc = subprocess.run(
        [MIMIR_BIN, "compile-gpu", src, "--backend", "msl", "--output", out_dir],
        capture_output=True, text=True, timeout=30, cwd=REPO_ROOT,
    )
    if proc.returncode != 0:
        return None, proc.stdout, proc.stderr
    metal_files = [f for f in os.listdir(out_dir) if f.endswith(".metal")]
    if len(metal_files) != 1:
        return None, proc.stdout, proc.stderr
    return os.path.join(out_dir, metal_files[0]), proc.stdout, proc.stderr


def write_f32_bin(path, values):
    with open(path, "wb") as f:
        f.write(struct.pack("<%df" % len(values), *values))


def run_device(entry, kernel_path, tensors, tmp_dir):
    """Invoke metal_run_bin `run` mode.
    Returns (status, device_flat_or_None, raw_stdout, raw_stderr) where
    status in {"DISPATCH_OK", "SKIPPED", "REFUSED"} — numeric correctness is
    judged by the caller (compare()), not here."""
    entry_name = "kernel_" + entry["func"]
    in_specs = []
    for i, (name, _shape, _gen) in enumerate(entry["inputs"]):
        p = os.path.join(tmp_dir, f"in_{i}_{name}.bin")
        write_f32_bin(p, tensors[i].data)
        in_specs.append("in:" + p)

    out_count = numel(entry["output_shape"])
    kind = entry["dispatch"][0]
    if kind == "1d":
        n = entry["dispatch"][1]
        dispatch_spec = f"1d:{n}"
    else:
        _kind, m, k, n = entry["dispatch"]
        dispatch_spec = f"2d:{m}:{k}:{n}"

    cmd = [METAL_RUN_BIN, "run", kernel_path, entry_name, dispatch_spec] + in_specs + [f"out:{out_count}"]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60, cwd=REPO_ROOT)

    if proc.returncode == 2 or "SKIPPED(no-GPU)" in proc.stdout:
        return "SKIPPED", None, proc.stdout, proc.stderr
    if proc.returncode != 0:
        return "REFUSED", None, proc.stdout, proc.stderr

    m = re.search(r"^OUT \d+ (\d+) (.+)$", proc.stdout, re.MULTILINE)
    if not m:
        return "REFUSED", None, proc.stdout, proc.stderr
    count = int(m.group(1))
    floats = [float(x) for x in m.group(2).split()]
    if len(floats) != count:
        return "REFUSED", None, proc.stdout, proc.stderr
    return "DISPATCH_OK", floats, proc.stdout, proc.stderr


def compare(entry, ref, actual):
    if len(ref) != len(actual):
        return False, float("inf")
    max_delta = 0.0
    for r, a in zip(ref, actual):
        d = abs(r - a)
        metric = d if entry["tol_kind"] == "abs" else d / max(1.0, abs(r))
        max_delta = max(max_delta, metric)
    return max_delta <= entry["tol"], max_delta


ROWS = []  # (name, result, max_delta_or_None, detail)


def parity_one(entry):
    tensors, ref_out = shim_reference(entry)
    with tempfile.TemporaryDirectory(prefix="kparity_") as tmp:
        kernel_path, _cstdout, cstderr = compile_kernel(entry, tmp)
        if kernel_path is None:
            ROWS.append((entry["name"], "FAIL", None, "compile-gpu failed: " + cstderr.strip()))
            return
        status, device_out, _dstdout, dstderr = run_device(entry, kernel_path, tensors, tmp)
        if status == "SKIPPED":
            ROWS.append((entry["name"], "SKIPPED(no-GPU)", None, dstderr.strip()))
            return
        if status == "REFUSED":
            ROWS.append((entry["name"], "FAIL", None, "metal_run refused: " + dstderr.strip()))
            return
        ok, max_delta = compare(entry, ref_out, device_out)
        ROWS.append((entry["name"], "PASS" if ok else "FAIL", max_delta,
                     "" if ok else f"exceeds tol {entry['tol']} ({entry['tol_kind']})"))


def print_table():
    print(f"{'kernel':<16} {'result':<20} {'max-delta':<14} detail")
    print("-" * 84)
    for name, result, max_delta, detail in ROWS:
        delta_str = f"{max_delta:.3e}" if max_delta is not None else "n/a"
        print(f"{name:<16} {result:<20} {delta_str:<14} {detail}")


def mutation_fail_proof():
    """D-G2v2 acceptance: prove a deliberately-broken kernel FAILs parity —
    never a silent PASS. Compiles vector_add, mutates the emitted MSL's `+`
    to `-` (wrong op), re-dispatches the mutated kernel, and checks the
    parity comparison reports FAIL with a nonzero max-delta."""
    entry = ENTRIES[0]  # vector_add
    tensors, ref_out = shim_reference(entry)
    with tempfile.TemporaryDirectory(prefix="kparity_mutation_") as tmp:
        kernel_path, _o, cstderr = compile_kernel(entry, tmp)
        if kernel_path is None:
            print("MUTATION-PROOF: INCONCLUSIVE (compile-gpu itself failed, cannot mutate): " + cstderr.strip())
            return False
        with open(kernel_path) as f:
            src = f.read()
        needle = "param_x[tid] + param_y[tid]"
        replacement = "param_x[tid] - param_y[tid]"
        if needle not in src:
            print(f"MUTATION-PROOF: INCONCLUSIVE (pattern {needle!r} not found in emitted MSL "
                  f"— emitter output format changed, update this proof to match)")
            return False
        mutated = src.replace(needle, replacement, 1)
        mutated_path = os.path.join(tmp, "mutated.metal")
        with open(mutated_path, "w") as f:
            f.write(mutated)
        status, device_out, _dstdout, _dstderr = run_device(entry, mutated_path, tensors, tmp)
        if status == "SKIPPED":
            print("MUTATION-PROOF: SKIPPED(no-GPU) — cannot prove FAIL fires without a device")
            return None
        if status == "REFUSED":
            print("MUTATION-PROOF: PASS (via REFUSED — dispatch itself rejected the mutated kernel; "
                  "still not a silent PASS, acceptable)")
            return True
        ok, max_delta = compare(entry, ref_out, device_out)
        if ok:
            print(f"MUTATION-PROOF: BROKEN — mutated kernel (+ -> -) still reported PASS "
                  f"(max-delta {max_delta:.3e})! The harness is not sensitive to this mutation.")
            return False
        print(f"MUTATION-PROOF: PASS — mutated kernel (+ -> -) correctly reported FAIL "
              f"(max-delta {max_delta:.3e} > tol {entry['tol']})")
        return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mutation-check", action="store_true",
                     help="run the deliberately-broken-kernel FAIL proof instead of the parity table")
    args = ap.parse_args()

    if not os.path.isfile(METAL_RUN_BIN):
        print(f"ERROR: {METAL_RUN_BIN} not found — build it first: "
              f"odin build tests/tools/metal_run.odin -file -out:{METAL_RUN_BIN}", file=sys.stderr)
        sys.exit(1)

    if args.mutation_check:
        ok = mutation_fail_proof()
        sys.exit(0 if ok else 1)

    for entry in ENTRIES:
        parity_one(entry)
    print_table()

    any_fail = any(r[1] == "FAIL" for r in ROWS)
    sys.exit(1 if any_fail else 0)


if __name__ == "__main__":
    main()
