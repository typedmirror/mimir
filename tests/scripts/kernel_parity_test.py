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
the comparison reports FAIL (not a silent PASS). A SECOND proof does the
same for a reduction-class kernel specifically (mean_n200's divisor,
`(float)200` -> `(float)256` — the exact historical D-G3v2 bug class: wrong-
divisor, not wrong-identity, since with a full N=256 or a nonzero-mean input
a wrong divisor is guaranteed to produce a detectably different result,
whereas an identity-value mutation on a kernel whose N happens to already
equal the true reduction identity can go unnoticed by coincidence). Both are
part of L2's BEFORE-DONE acceptance, not optional.

REDUCTION-CLASS DEV cases (this re-engagement, scoped extension while
menagerie authors the 9 Tier-2 zoo rows): tests/gpu/reduction_sizes.py (L4/
candor's own fixture — never zoo/, never tests/gpu/reduction.py/softmax.py,
which are L1's) is wired as DEV_ENTRIES below: 4 reductions (sum/mean/max/
min, N=64..256, output buffer length 1, compared against shim reference
result[0]) + 1 softmax (N=100, full-length output, elementwise compare).
These are proof-of-dispatch cases, not zoo rows — they exist to prove the
"reduce" dispatch mode (see tests/tools/metal_run.odin: parses the emitted
kernel's own "exactly 1 threadgroup of N threads" comment, dispatches
exactly that many threads in exactly one threadgroup — under-dispatching a
reduction whose N < the block width leaves shared-memory tail slots
uninitialized, which is silently wrong, not a crash) ahead of the real zoo
Tier-2 entries landing. Once menageries's zoo/{relu,sigmoid,...,softmax}.py
etc. post `done`, wiring their ENTRIES rows is mechanical (same dispatch
machinery, same "reduce" kind, tolerance read from each entry's own
docstring per D-G2v2's per-entry-with-derivation requirement) — the DEV
proof is what de-risks that wiring being correct on day one.

DEV inputs use directly-constructed non-uniform deterministic values (a
small closed-form ramp, NOT ones()/zeros()) rather than menagerie's zoo
runnable-leg convention: menagerie's convention is a constraint on zoo/*.py
FILES (those must `mimir check` clean, so creation calls are checker-
supported no-arg-shape functions). This script is pure test-driver code —
never `mimir check`ed itself — so no such constraint applies, and uniform
inputs are numerically weaker here: a reduction/softmax bug that swaps or
skips indices is invisible when every element holds the same value (learned
the hard way with Tier-1's matmul row/col bug, where the constant-input
zoo `__main__` blocks alone would NOT have caught it — only an elementwise
compare across a real computed shape did). Reduction identity/tail-guard
bugs (D-G3v2's actual bug class) are magnitude-detectable even with
constant input, but a varied input is strictly more sensitive and costs
nothing extra here.

Tolerance for DEV reductions: RELATIVE, derived from n * float32-epsilon
(D-G2v2's "relative tol derived from n * eps, stated per-entry" — see
REL_TOL_FACTOR below for the derivation and safety margin). max()/min() are
pure selection (no arithmetic accumulation) so their true error is exactly
zero; a small absolute tolerance is used for them as a float-representation
safety margin, not because rounding accumulates.

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
DEV_DIR = os.environ.get("DEV_DIR", os.path.join(REPO_ROOT, "tests", "gpu"))
MIMIR_BIN = os.environ.get("MIMIR_BIN", os.path.join(REPO_ROOT, "mimir_bin"))
METAL_RUN_BIN = os.environ.get(
    "METAL_RUN_BIN", os.path.join(REPO_ROOT, "tests", "tools", "metal_run_bin")
)

sys.path.insert(0, os.path.join(REPO_ROOT, "python"))
from mimir.array import Tensor, ones, zeros  # noqa: E402 - sys.path must be set first

# float32 machine epsilon (2^-23) — the derivation base for reduction/
# softmax relative tolerances (D-G2v2: "RELATIVE tol derived from n * eps,
# stated per-entry"). Safety factor covers the tree-reduction's log2(256)=8
# summation levels plus (for softmax) the extra exp()/division rounding —
# generous on purpose: this guards against real regressions, not float
# noise between runs.
F32_EPS = 2.0 ** -23
REL_TOL_FACTOR = 16.0


def rel_tol(n):
    return max(1e-6, n * F32_EPS * REL_TOL_FACTOR)


def numel(shape):
    n = 1
    for s in shape:
        n *= s
    return n


def ramp(n, a=37, b=11, m=97, scale=0.1, offset=0.5):
    """Deterministic non-uniform values — see module docstring for why DEV
    cases use this instead of ones()/zeros()."""
    return Tensor.from_flat([((i * a + b) % m) * scale + offset for i in range(n)], (n,))


# neg_ones / two: match zoo/relu.py's `zeros(N) - ones(N)` (= -1 everywhere,
# exercises relu's clamp branch) and zoo/saxpy.py's `ones(1) + ones(1)`
# (= [2.0], keeps `a` a real Tensor[float32,1] rather than a raw Python
# scalar) EXACTLY as each entry's own __main__ block constructs them —
# these are each entry's documented runnable-leg convention, not invented
# here.
def neg_ones(*shape):
    return zeros(*shape) - ones(*shape)


def two(*shape):
    return ones(*shape) + ones(*shape)


GEN = {"ones": ones, "zeros": zeros, "ramp": ramp, "neg_ones": neg_ones, "two": two}


# ---- Tier-1 entry table -------------------------------------------------
# Mirrors zoo/{vector_add,squared_error,linear_forward,matmul}.py exactly
# (function names, shapes, seeded-input generators) as authored by L3
# "menagerie". All four are elementwise or matmul (no reductions in Tier 1),
# so all use a flat absolute tolerance per D-G2v2 ("elementwise/matmul: abs
# tol 1e-5"). source_dir defaults to ZOO_DIR when omitted (see entry_dir()).
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

# ---- Tier-2 entry table --------------------------------------------------
# Mirrors zoo/{relu,sigmoid,elementwise_math,saxpy,sum_reduce,max_reduce,
# mean,mse_loss,softmax}.py exactly (function names, shapes, seeded-input
# generators, dispatch requirements) as authored by L3 "menagerie" — gated
# on L1 + D-G3v2 + D-G4v2(c)/(e)/(f) all merged, per N3, and now landed.
# Tolerances are READ FROM each entry's own docstring (D-G2v2: "per-entry
# RELATIVE for reductions/softmax read from the entry docstring convention")
# rather than re-derived here — 3.05e-5 = 256 * float32-eps (N * eps_f32,
# eps_f32 = 2^-23), the exact number menagerie's docstrings state for every
# N=256 reduction/softmax entry, including max_reduce (which docstrings its
# own honest caveat that a max-tree's real error is 0 — the RELATIVE
# 3.05e-5 figure is stated for convention-consistency across the five
# reduction/softmax entries, and this table follows that authored contract
# rather than substituting a tighter bound the docstring didn't declare).
ENTRIES += [
    {
        "name": "relu",
        "file": "relu.py",
        "func": "relu",
        "inputs": [("x", (256,), "neg_ones")],
        "output_shape": (256,),
        "dispatch": ("1d", 256),
        "tol_kind": "abs",
        "tol": 1e-5,
    },
    {
        "name": "sigmoid",
        "file": "sigmoid.py",
        "func": "sigmoid",
        "inputs": [("x", (256,), "zeros")],
        "output_shape": (256,),
        "dispatch": ("1d", 256),
        "tol_kind": "abs",
        "tol": 1e-5,
    },
    {
        "name": "elementwise_math",
        "file": "elementwise_math.py",
        "func": "elementwise_math",
        "inputs": [("x", (256,), "ones")],
        "output_shape": (256,),
        "dispatch": ("1d", 256),
        "tol_kind": "abs",
        "tol": 1e-5,
    },
    {
        "name": "saxpy",
        "file": "saxpy.py",
        "func": "saxpy",
        "inputs": [("a", (1,), "two"), ("x", (256,), "ones"), ("y", (256,), "ones")],
        "output_shape": (256,),
        "dispatch": ("1d", 256),
        "tol_kind": "abs",
        "tol": 1e-5,
    },
    {
        "name": "sum_reduce",
        "file": "sum_reduce.py",
        "func": "sum_reduce",
        "inputs": [("x", (256,), "ones")],
        "output_shape": (1,),
        "dispatch": ("reduce",),
        "tol_kind": "relative",
        "tol": 3.05e-5,
    },
    {
        "name": "max_reduce",
        "file": "max_reduce.py",
        "func": "max_reduce",
        "inputs": [("x", (256,), "ones")],
        "output_shape": (1,),
        "dispatch": ("reduce",),
        "tol_kind": "relative",
        "tol": 3.05e-5,
    },
    {
        "name": "mean",
        "file": "mean.py",
        "func": "mean",
        "inputs": [("x", (256,), "ones")],
        "output_shape": (1,),
        "dispatch": ("reduce",),
        "tol_kind": "relative",
        "tol": 3.05e-5,
    },
    {
        "name": "mse_loss",
        "file": "mse_loss.py",
        "func": "mse_loss",
        "inputs": [("pred", (256,), "ones"), ("target", (256,), "zeros")],
        "output_shape": (1,),
        "dispatch": ("reduce",),
        "tol_kind": "relative",
        "tol": 3.05e-5,
    },
    {
        "name": "softmax",
        "file": "softmax.py",
        "func": "softmax",
        "inputs": [("x", (256,), "ones")],
        "output_shape": (256,),
        "dispatch": ("reduce",),
        "tol_kind": "relative",
        "tol": 3.05e-5,
    },
]

# ---- Reduction-class DEV entries (re-engagement, ahead of Tier-2) -------
# tests/gpu/reduction_sizes.py, L4/candor's own fixture (source_dir=DEV_DIR,
# never ZOO_DIR — these are proof-of-dispatch cases, not zoo rows). Every
# size here is <= the single-workgroup bound (256) with at least one
# non-256 size per op, matching D-G3v2's own requirement for its fixture.
# dispatch=("reduce",) selects metal_run's comment-parsing dispatch mode
# (see tests/tools/metal_run.odin) — no size is hand-supplied here, by
# design: the whole point is proving the parser reads the kernel's own
# stated requirement rather than the harness assuming a width.
DEV_ENTRIES = [
    {
        "name": "dev_sum_n100",
        "source_dir": DEV_DIR,
        "file": "reduction_sizes.py",
        "func": "sum_n100",
        "inputs": [("x", (100,), "ramp")],
        "output_shape": (1,),
        "dispatch": ("reduce",),
        "tol_kind": "relative",
        "tol": rel_tol(100),
    },
    {
        "name": "dev_mean_n200",
        "source_dir": DEV_DIR,
        "file": "reduction_sizes.py",
        "func": "mean_n200",
        "inputs": [("x", (200,), "ramp")],
        "output_shape": (1,),
        "dispatch": ("reduce",),
        "tol_kind": "relative",
        "tol": rel_tol(200),
    },
    {
        "name": "dev_max_n256",
        "source_dir": DEV_DIR,
        "file": "reduction_sizes.py",
        "func": "max_n256",
        "inputs": [("x", (256,), "ramp")],
        "output_shape": (1,),
        "dispatch": ("reduce",),
        "tol_kind": "abs",  # pure selection, no accumulated rounding
        "tol": 1e-6,
    },
    {
        "name": "dev_min_n64",
        "source_dir": DEV_DIR,
        "file": "reduction_sizes.py",
        "func": "min_n64",
        "inputs": [("x", (64,), "ramp")],
        "output_shape": (1,),
        "dispatch": ("reduce",),
        "tol_kind": "abs",  # pure selection, no accumulated rounding
        "tol": 1e-6,
    },
    {
        "name": "dev_softmax_n100",
        "source_dir": DEV_DIR,
        "file": "reduction_sizes.py",
        "func": "softmax_n100",
        "inputs": [("x", (100,), "ramp")],
        "output_shape": (100,),
        "dispatch": ("reduce",),
        "tol_kind": "relative",
        "tol": rel_tol(100),
    },
]


def entry_dir(entry):
    return entry.get("source_dir", ZOO_DIR)


def load_module(path, modname):
    spec = importlib.util.spec_from_file_location(modname, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def shim_reference(entry):
    """Run the real @gpu function under the pure-Python shim with the
    entry's documented seeded inputs. Returns (input_tensors, output_flat)."""
    path = os.path.join(entry_dir(entry), entry["file"])
    mod = load_module(path, entry["name"] + "_zoomod")
    func = getattr(mod, entry["func"])
    tensors = [GEN[gen](*shape) for _name, shape, gen in entry["inputs"]]
    out = func(*tensors)
    return tensors, list(out.data)


def compile_kernel(entry, out_dir):
    """compile-gpu compiles the WHOLE source file — for zoo/*.py (one @gpu
    function per file) that's a single .metal, but tests/gpu/reduction_sizes
    .py (L4's DEV fixture) has 5 @gpu functions and emits 5 .metal files in
    one pass. Select by the entry's own function name (compile-gpu names
    each output <func_name>.metal) rather than assuming exactly one file —
    a genuinely missing/misnamed output is still a FAIL, just detected by
    name instead of by count."""
    src = os.path.join(entry_dir(entry), entry["file"])
    proc = subprocess.run(
        [MIMIR_BIN, "compile-gpu", src, "--backend", "msl", "--output", out_dir],
        capture_output=True, text=True, timeout=30, cwd=REPO_ROOT,
    )
    if proc.returncode != 0:
        return None, proc.stdout, proc.stderr
    expected = os.path.join(out_dir, entry["func"] + ".metal")
    if not os.path.isfile(expected):
        return None, proc.stdout, proc.stderr + f"\n(expected {expected!r} not found among emitted files)"
    return expected, proc.stdout, proc.stderr


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
    elif kind == "reduce":
        # No size passed — metal_run parses the kernel's own dispatch-
        # requirement comment (see tests/tools/metal_run.odin).
        dispatch_spec = "reduce"
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


def parity_one(entry, rows):
    tensors, ref_out = shim_reference(entry)
    with tempfile.TemporaryDirectory(prefix="kparity_") as tmp:
        kernel_path, _cstdout, cstderr = compile_kernel(entry, tmp)
        if kernel_path is None:
            rows.append((entry["name"], "FAIL", None, "compile-gpu failed: " + cstderr.strip()))
            return
        status, device_out, _dstdout, dstderr = run_device(entry, kernel_path, tensors, tmp)
        if status == "SKIPPED":
            rows.append((entry["name"], "SKIPPED(no-GPU)", None, dstderr.strip()))
            return
        if status == "REFUSED":
            rows.append((entry["name"], "FAIL", None, "metal_run refused: " + dstderr.strip()))
            return
        ok, max_delta = compare(entry, ref_out, device_out)
        rows.append((entry["name"], "PASS" if ok else "FAIL", max_delta,
                     "" if ok else f"exceeds tol {entry['tol']} ({entry['tol_kind']})"))


def print_table(rows, title):
    print(title)
    print(f"{'kernel':<20} {'result':<20} {'max-delta':<14} detail")
    print("-" * 88)
    for name, result, max_delta, detail in rows:
        delta_str = f"{max_delta:.3e}" if max_delta is not None else "n/a"
        print(f"{name:<20} {result:<20} {delta_str:<14} {detail}")
    print()


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


def mutation_fail_proof_reduction():
    """D-G2v2 acceptance (this re-engagement): prove FAIL fires on a
    reduction-class kernel specifically, via a WRONG-DIVISOR mutation —
    the exact historical D-G3v2 bug class (mean dividing by the 256 block
    bound instead of the real N). Uses dev_mean_n200: mutates the emitted
    MSL's `(float)200` divisor to `(float)256`. A wrong-divisor mutation is
    guaranteed to be detectable for any nonzero-sum input (unlike a wrong-
    identity mutation on a kernel whose true reduction value happens to
    coincide with the identity value by chance of the chosen input)."""
    entry = next(e for e in DEV_ENTRIES if e["name"] == "dev_mean_n200")
    tensors, ref_out = shim_reference(entry)
    with tempfile.TemporaryDirectory(prefix="kparity_mutation_reduce_") as tmp:
        kernel_path, _o, cstderr = compile_kernel(entry, tmp)
        if kernel_path is None:
            print("MUTATION-PROOF(reduce): INCONCLUSIVE (compile-gpu itself failed, cannot mutate): "
                  + cstderr.strip())
            return False
        with open(kernel_path) as f:
            src = f.read()
        needle = "(float)200"
        replacement = "(float)256"
        if needle not in src:
            print(f"MUTATION-PROOF(reduce): INCONCLUSIVE (pattern {needle!r} not found in emitted MSL "
                  f"— emitter output format changed, update this proof to match)")
            return False
        mutated = src.replace(needle, replacement, 1)
        mutated_path = os.path.join(tmp, "mutated.metal")
        with open(mutated_path, "w") as f:
            f.write(mutated)
        status, device_out, _dstdout, _dstderr = run_device(entry, mutated_path, tensors, tmp)
        if status == "SKIPPED":
            print("MUTATION-PROOF(reduce): SKIPPED(no-GPU) — cannot prove FAIL fires without a device")
            return None
        if status == "REFUSED":
            print("MUTATION-PROOF(reduce): PASS (via REFUSED — dispatch itself rejected the mutated "
                  "kernel; still not a silent PASS, acceptable)")
            return True
        ok, max_delta = compare(entry, ref_out, device_out)
        if ok:
            print(f"MUTATION-PROOF(reduce): BROKEN — wrong-divisor mutation (200 -> 256) still reported "
                  f"PASS (max-delta {max_delta:.3e})! The harness is not sensitive to this mutation.")
            return False
        print(f"MUTATION-PROOF(reduce): PASS — wrong-divisor mutation (200 -> 256) correctly reported "
              f"FAIL (max-delta {max_delta:.3e} > tol {entry['tol']:.3e})")
        return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mutation-check", action="store_true",
                     help="run both deliberately-broken-kernel FAIL proofs (elementwise + reduction) "
                          "instead of the parity tables")
    args = ap.parse_args()

    if not os.path.isfile(METAL_RUN_BIN):
        print(f"ERROR: {METAL_RUN_BIN} not found — build it first: "
              f"odin build tests/tools/metal_run.odin -file -out:{METAL_RUN_BIN}", file=sys.stderr)
        sys.exit(1)

    if args.mutation_check:
        ok1 = mutation_fail_proof()
        ok2 = mutation_fail_proof_reduction()
        overall = (ok1 is True) and (ok2 is True)
        sys.exit(0 if overall else 1)

    zoo_rows = []
    for entry in ENTRIES:
        parity_one(entry, zoo_rows)
    print_table(zoo_rows, "zoo/ parity — 13 entries (4 Tier-1 + 9 Tier-2):")

    dev_rows = []
    for entry in DEV_ENTRIES:
        parity_one(entry, dev_rows)
    print_table(dev_rows, "DEV reduction/softmax dispatch proof (tests/gpu/reduction_sizes.py, not zoo rows):")

    any_fail = any(r[1] == "FAIL" for r in zoo_rows) or any(r[1] == "FAIL" for r in dev_rows)
    sys.exit(1 if any_fail else 0)


if __name__ == "__main__":
    main()
