# RECEIPTS

Every number mimir's launch materials cite is reproducible from this repo in
about 20 minutes on your own machine. This document is that reproduction —
commands, expected output, and what each one actually proves. If a number
here doesn't match what you get, that's a bug in our claim, not yours; file
it.

Nothing in this document is aspirational. Every command below was run
against this repo, and the output shown is what came back, unedited except
for trimming. Final full re-verification pass (all gates, the planted-bug
demo, and the dual-execution proof, all re-run together to confirm nothing
drifted) was at commit `3c891df`.

## Prerequisites

- **Odin compiler.** mimir is written in Odin, zero other implementation
  languages. Built and verified here with `dev-2026-03:1a5126c6b`
  (`odin version`). No minimum version is pinned in this repo; if a newer
  Odin breaks the build, that's worth reporting.
- **python3.** Several gates are Python test-runner scripts over the Odin
  binary's output — no Python is compiled or shipped, the scripts just
  drive the binary and diff results.
- No other dependencies. No virtualenv, no package manager, no network
  access required for the four core gates, the planted-bug demo, or the
  dual-execution proof. The "Honest limits" section needs two external
  clones (mypy's test corpus, python/typing's conformance suite) — called
  out explicitly there, with fetch commands.

## Build from source

```bash
git clone <this-repo> mimir && cd mimir
odin build src/ -collection:mimir=src/ -out:mimir -o:speed
cp mimir mimir_bin   # test scripts invoke ./mimir_bin specifically
```

Measured on a MacBook Air M3: **~22 seconds wall clock** (19.6s user, 0.6s
system). Output is a single ~2.8MB binary with no runtime dependencies —
`ldd`/`otool -L` it if you want to confirm that yourself.

As a reproducibility check, the binary rebuilt fresh from source for this
document was diffed against the tree's existing `mimir_bin` on the planted-bug
fixture below (`check tests/fixtures/trust_t1/gpu_shape/bad_matmul.py`):
output was byte-identical. The source tree, not the binary, is the source of
truth.

## Gate 1 — conformance corpus

```bash
$ ./mimir_bin conform
```
```
mimir conform: 617/617 passed, 664/664 markers matched
```

What it proves: 617 fixture files, each carrying inline `# E[CODE]` markers
that assert *which diagnostic code fires on which line* (not just "some
error somewhere"). A fixture with a missing or wrong-code diagnostic fails
the run. 664 is the marker count across those files (some files assert more
than one diagnostic). This is mimir's own quality bar — see the "honest
limits" section below for why this number is not compared to any external
suite's pass rate.

## Gate 2 — trust fixtures (T1)

```bash
$ python3 tests/scripts/t1_trust_test.py
```
```
PASS  sibling: no-marker sibling resolution catches planted bugs (T1b acceptance)
PASS  unresolved: loud B003 + summary; independent checks still fire (T1a + T1c)
PASS  relative: package-relative import in single-file mode → B003; summary on SUCCESS exit
PASS  parse_drop/stmt: P001 statement drop (one per line) + analysis continues (T1d)
PASS  parse_drop/indent: P001 unexpected indentation (T1d)
PASS  clean: FP guard — resolvable imports produce NO B003/P001/summary
PASS  precedence: local sibling SHADOWS stdlib module of the same name (sys.path[0] parity)
PASS  dotted: dotted sibling target (mypkg/util.py, namespace style) resolves
PASS  t2/typevar-d001: annotation-used TypeVars never D001; dead ones still flagged
PASS  gpu_shape/positive: D6 precedence — exactly ONE error (GPU011) on the planted matmul line; S001/SHAPE001/T003 all suppressed
PASS  gpu_shape/negative: genuine shaped-vs-shaped return mismatch still fires
PASS  t5/import-requests (exit 0, no signal)
PASS  t5/import-urllib3 (exit 0, no signal)
PASS  t5/conc_blocking.py (exit 1, no signal)
PASS  t5/sec_supply_chain.py (exit 1, no signal)
PASS  t5/conformance-dir-mode (exit 1, no signal)

t1_trust: 11/11 fixture cases passed
```

What it proves: these are the "don't lie to the user" fixtures — cases
where a naive implementation would silently drop an error, double-count a
diagnostic, or crash instead of reporting. Each case is a specific known
failure mode from earlier in this project's history, turned into a
permanent regression test.

## Gate 3 — LSP smoke test

```bash
$ python3 tests/scripts/lsp_smoke_test.py
```
```
published diagnostics: 18
didOpen->publish: 1.2 ms | didChange->publish: 0.7 ms
lsp_smoke: PASS (18 diagnostics)
```

What it proves: the language-server-protocol path (`mimir lsp`) is a
separate code path from the CLI checker and can silently drift out of sync
with it. This drives a real didOpen/didChange round trip and checks
diagnostics actually get published, with latency low enough to be
interactive.

## Gate 4 — every diagnostic code fires

```bash
$ python3 tests/scripts/every_code_fires.py
```
```
== inventory (see docstring for the two counting rules) ==
distinct code-shaped literals in src/:        171
naive `code = "X"` grep (incl. explain.odin): 161
  named-field emission sites (excl. explain): 124
  emitted ONLY via positional emit helpers:   43
EMITTABLE (union of both emission kinds):     167
excluded, no emission site (4):
  DATA003    appears only as: explain-DB
  E001       appears only as: comment
  T011       appears only as: case-list
  W042       appears only as: comment

== corpus run: check/lint/audit/perf/safety over tests/conformance + tests/smoke ==
fired: 141/167 emittable codes
silent: 26 codes never fired across the corpus:
  API005 DATA002 DB002 E000 GPU012 GPU013 JSON002 JSON003 M001
  MIG001 MIG002 MIG003 MIG004 MIG005 MIG006 MIG007 MIG008 TEST001
  WASM001 WASM002 WASM003 WASM004 WASM005 WASM006 WASM007 WASM008

== waivers (tests/scripts/silent_code_waivers.txt) ==
waived silent codes: 26

gate: PASS — every emittable code fires or carries a justified waiver
```
(exit code 0)

What this means, plainly: mimir has 167 diagnostic codes it can actually
emit. This gate statically inventories every one of them, runs the full
corpus (conformance + smoke fixtures) through every analysis command, and
checks each code fired at least once. A code that never fires is either
dead code pretending to be a feature, or a real capability with no test
proving it works — both are bugs. Every one of the 26 codes that didn't
fire in this corpus carries a written justification in
`tests/scripts/silent_code_waivers.txt` (mostly: codes that belong to
unimplemented subsystems — MIG*/WASM*/JSON002-3/DB002/DATA002 — declared,
not wired up yet, and honestly labeled as such rather than silently
included in the "167" count as if they worked). This is the project's
answer to "how do you know your green checkmarks mean anything": a gate
that fails the build if a diagnostic code goes silent without anyone
noticing.

## Planted-bug demo

A hand-planted shape bug, checked live:

```python
# tests/fixtures/trust_t1/gpu_shape/bad_matmul.py
"""GPU integration: shape error caught in @gpu function (D6 enforcement copy)."""

from mimir.array import Tensor, gpu, float32

@gpu
def bad_matmul(
    x: Tensor[float32, 32, 784],
    w: Tensor[float32, 128, 10],   # WRONG: inner dim 784 != 128
) -> Tensor[float32, 32, 10]:
    return x @ w  # planted: GPU011 only — S001/SHAPE001/T003 must not also fire
```

```bash
$ ./mimir_bin check tests/fixtures/trust_t1/gpu_shape/bad_matmul.py
```
```
tests/fixtures/trust_t1/gpu_shape/bad_matmul.py:10:11: error[GPU011]: matmul shape mismatch: left has K=784, right has K=128
  why: matrix multiplication requires inner dimensions to match (A[M,K] @ B[K,N])
  fix: ensure the inner dimensions of both matrices are equal
  checked tests/fixtures/trust_t1/gpu_shape/bad_matmul.py (3 stmts, 164 symbols, 3 scopes, 4 blocks, 0 guards, 1332 types)
mimir: 1 file(s) had errors
```
(exit code 1)

Exactly one diagnostic (`GPU011`), on the exact line with the planted
mismatch — 784 vs. 128 in the inner matmul dimension — with no duplicate or
contradictory diagnostics from mimir's other type/shape subsystems on the
same expression. That "exactly one" property is itself gate-tested (Gate 2,
`gpu_shape/positive` above); three separate shape-checking systems live in
this codebase (call-form shape checks, symbolic-dimension constraints, and
the GPU compute-graph checker) and a naive implementation would double- or
triple-report this.

## Dual-execution proof

A mimir `@gpu` kernel is ordinary typed Python — it's meant to run two
places unmodified: interpreted under plain CPython for debugging, and
statically checked + compiled to a real GPU kernel for shipping. Same file,
both paths, run live below.

The kernel:

```python
# tests/gpu/shape_integration.py
"""GPU integration: shapes from annotations → compute graph → validated kernel."""

from mimir.array import Tensor, gpu, float32

@gpu
def linear_forward(
    x: Tensor[float32, 32, 784],
    w: Tensor[float32, 784, 128],
    b: Tensor[float32, 128],
) -> Tensor[float32, 32, 128]:
    h = x @ w        # (32,784) @ (784,128) → (32,128)
    return h + b      # (32,128) + (128,) → broadcast
```

**Path 1 — interpreted.** `python/mimir/array.py` (tracked, ~350 lines, zero
dependencies) is a runtime shim: `gpu` is an identity decorator, `Tensor` is
a flat-buffer nested-list wrapper with broadcasting arithmetic and matmul.
It exists purely so you can set a breakpoint or sanity-check a kernel's
logic under CPython — it is not a performance target, and mimir's checker
never reads it.

```bash
$ PYTHONPATH=python python3 tests/gpu/shape_integration.py; echo EXIT:$?
```
```
EXIT:0
```

The file only defines `linear_forward` at module scope and nothing in it
calls the function, so this run proves the `Tensor[float32, 32, 784]`-style
subscript annotation is legal at runtime (`Tensor.__class_getitem__`) and
that the module imports cleanly under plain CPython — it does not by itself
prove the matmul/broadcast math is correct.

That's a separate, tracked check:

```bash
$ PYTHONPATH=python python3 tests/scripts/shim_functional_test.py; echo EXIT:$?
```
```
PASS  Tensor.__matmul__: ones(2,3) @ ones(3,4) shape (2, 4)
PASS  Tensor.__matmul__: ones(2,3) @ ones(3,4) == 3.0 everywhere
PASS  linear_forward: output shape (32, 128)
PASS  linear_forward: matches independent matmul+broadcast-add reference
PASS  exp_log: output shape (512,)
PASS  exp_log: log(exp(x)) round-trips to x within 1e-6
PASS  sqrt_pow: output shape (256,)
PASS  sqrt_pow: matches independent sqrt(x)+x**y reference
PASS  clamp_abs: output shape (128,)
PASS  clamp_abs: matches abs() reference
PASS  train_step: output shape (32, 10)
PASS  train_step: matches independent forward+MSE reference

shim_functional_test: 12/12 checks passed
EXIT:0
```

The first two lines need no independent reference code to trust — `ones(2,3)
@ ones(3,4)` is arithmetic you can do in your head (each output cell sums
three 1×1 terms, so every cell is 3.0); it's calling the shim's real
`Tensor.__matmul__` operator directly, not a kernel. The rest calls the real
kernel functions (`linear_forward`, `exp_log`, `sqrt_pow`, `clamp_abs`,
`train_step`, loaded straight from `tests/gpu/*.py`) with seeded tensors
from the shim's own `randn()`, and checks every output against a reference
matmul/broadcast/MSE implementation written from scratch inside the test
file — deliberately not sharing code with `Tensor`'s own
`__matmul__`/`__add__`, so a bug common to both "kernel" and "checker"
can't hide. It isn't a rubber stamp: flip a sign in the reference matmul and
`linear_forward` and `train_step` (the two checks that go through matmul)
fail while the independent `exp_log`/`sqrt_pow`/`clamp_abs` checks correctly
keep passing — verified by hand before this went in the document.

**Path 2 — checked, then compiled.** Same file, no changes:

```bash
$ ./mimir_bin check tests/gpu/shape_integration.py
```
```
  checked tests/gpu/shape_integration.py (3 stmts, 166 symbols, 3 scopes, 4 blocks, 0 guards, 1333 types)
mimir: successfully checked 1 file(s)
```

```bash
$ ./mimir_bin compile-gpu tests/gpu/shape_integration.py --backend msl
```
```
#include <metal_stdlib>
using namespace metal;

kernel void kernel_linear_forward(
    device const float* param_x [[buffer(0)]],
    device const float* param_w [[buffer(1)]],
    device const float* param_b [[buffer(2)]],
    device float* result [[buffer(3)]],
    constant uint3& dims [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint row = gid.x;
    uint col = gid.y;
    uint M = dims.x, K = dims.y, N = dims.z;
    float v4 = 0;
    for (uint k = 0; k < K; k++) {
        v4 += param_x[row * K + k] * param_w[k * N + col];
    }
    float v5 = v4 + param_b[col];
    result[row * N + col] = v5;
}

mimir compile-gpu: emitted 1 kernel(s)
```

Real Metal Shading Language, no Python runtime attached, generated
statically from the same annotated Python function that just ran under
CPython above. `mimir_bin` never reads `python/` from disk to do this —
`from mimir.array import ...` resolves against a virtual-module table
compiled into the checker (`gpu/virtual_modules.odin`); the `python/`
package on disk is inert as far as the checker is concerned, which is why
the two paths can't drift against each other silently.

Note the broadcast term is indexed `param_b[col]`, not `param_b[tid]` — an
earlier build of this kernel emitted a reference to an undeclared `tid` in
2D fused kernels (invalid MSL, would have failed to compile on real
hardware). Fixed and gate-tested: `tests/scripts/gpu_emit_backend_test.py`
(tracked, in CI) asserts both that this exact fixture emits with no orphan
`tid` reference and that the broadcast is indexed by the correct grid
coordinate, on both the MSL and WGSL backends. The same gate is also where
mimir's "refuse, don't mis-compile" discipline gets checked: feed it
`tests/gpu/training_step.py` (two chained matmuls of incompatible shapes
that a single fused kernel can't represent) and `compile-gpu` refuses
outright —

```bash
$ ./mimir_bin compile-gpu tests/gpu/training_step.py --backend msl; echo EXIT:$?
```
```
mimir compile-gpu: msl: kernel 'train_step' chains multiple matmuls with different shapes ([32,784]x[784,256] vs [32,256]x[256,10]) in one unfused kernel — a single `dims` (M,K,N) uniform cannot represent both; use --fuse to split into separate kernels
mimir compile-gpu: emitted 0 kernel(s), refused 1
EXIT:1
```

— nonzero exit, a diagnostic naming the specific shape conflict, and
"refused 1" stated explicitly in the summary, rather than silently emitting
nothing (or, worse, something wrong) with a clean exit code.

## Honest limits

Two numbers we could inflate, and don't.

**mypy's own unit-test corpus: 2913/6029 (48.3%).** This is *not* a
comparison against mypy's checker output on your code — it's mimir run
against mypy's own regression-test corpus (`test-data/unit/check-*.test`),
which exercises deep, adversarial corners of the Python type system mypy
was built to cover.

This corpus is **not vendored in this repo** — it's an external pinned
checkout, and the pass rate is only meaningful when measured against the
exact same commit everyone else measures against:

```bash
git clone --filter=blob:none https://github.com/python/mypy.git /path/to/mypy
git -C /path/to/mypy checkout 25b210d2cdf3f5d4e17a96eb7ed25f54456bc631
python3 tests/scripts/mypy_test_runner.py --mypy-dir /path/to/mypy
```

(Full pin details, verification steps, and runner behavior on a
mismatched/missing checkout: `tests/scripts/MYPY_DEP.md`, tracked in this
repo.) Re-run above against the pinned commit for this document:

```
Total cases:   8034
Skipped:       2005 (multi-file, out-only, python2, etc.)
Run:           6029
Passed:        2913
Failed:        3116
Pass rate:     48.3%
```

We track this number. We do not target it — mimir was never built to
maximize mypy-test-corpus pass rate, and "faster mypy" is an explicitly
retired positioning for this project. It's published because hiding an
inconvenient number is worse than publishing a modest one.

**python/typing official conformance suite: 15.0% line-level hit rate.**
`github.com/python/typing`'s `conformance/tests/` (141 scored files, at the
commit noted below) is the closest thing the Python ecosystem has to an
official PEP-conformance suite. We run a line-level sweep against it — not
the suite's own scoring harness (which needs `uv` + per-checker adapters and
produces a spec-clause-level score; ours is coarser: for every line the
suite marks as requiring an error, did mimir emit *any* diagnostic there).
Unlike every other section in this document, **this suite is not vendored
and not pinned to a commit** — it moves upstream, and the number is expected
to drift release to release. What makes it a gate rather than a one-off
claim is that the sweep script is tracked in this repo, so you regenerate
the number yourself instead of trusting ours:

```bash
git clone --depth 1 https://github.com/python/typing.git typing-suite
python3 tests/scripts/official_typing_scorecard.py
```

(Default suite location is `./typing-suite`, relative to wherever you run the
script from; override with `--suite-dir PATH` or the `TYPING_SUITE_DIR` env
var if you cloned it elsewhere.)

Our run, for the record — commit `043e01d99dfdbfdf671f0de47f04ec6d7bf1c791`,
pulled 2026-08-10:

```
Suite commit:             043e01d99dfdbfdf671f0de47f04ec6d7bf1c791
Files swept:               141
Crashes:                   0
Timeouts:                  0
Required-error lines:      1137
Lines hit:                 170
Overall hit rate:          15.0%
False-positive lines:      186
Optional (# E?) lines:     94 (excluded from scoring)
Files 0/N hit:             73/141
Files fully clean:         3/141
```

Strongest categories: constructors (44.8%), namedtuples (41.2%), tuples
(38.8%) — areas that overlap with mimir's constructor-arg and tensor-shape
checking. Weakest: overloads, enums, annotations, historical, and typeforms
score at or near 0% — mimir has no overload-consistency checker and thin
enum/typing-forms semantic coverage; this is an acknowledged coverage gap,
not a claimed strength. Full category breakdown: `docs/SCORECARD_OFFICIAL_TYPING.md`
(not tracked — regenerate it yourself with `--json` for the per-file detail).

If your run's numbers differ from ours: expected, and not a bug in either of
us. The suite isn't pinned, so a newer or older checkout will score
differently — check the commit hash your run prints against
`043e01d99dfdbfdf671f0de47f04ec6d7bf1c791` before assuming something's wrong.

The candor here is the point: mimir was built as a tensor-shape/dtype/
device checker for GPU kernels, not a general-purpose PEP-conformance
engine. 15.0% against a suite testing the entire modern typing spec —
overloads, enum semantics, type-alias variance, structural protocols — is
what you'd expect from that scope, not a regression to be alarmed by.

## What this document does not claim

- It does not claim mimir is better than mypy, pyright, or any other
  checker at general Python type checking. The honest-limits section above
  says the opposite for two specific, named benchmarks.
- It does not claim GPU-kernel compilation is production-grade or
  performance-tuned. `compile-gpu` emits correct, statically-verified MSL —
  gate-tested by `tests/scripts/gpu_emit_backend_test.py` (tracked, in CI),
  which checks emitted-code structure on both the MSL and WGSL backends and
  confirms that patterns the backend can't represent (see the
  `training_step.py` refusal above) are refused with a nonzero exit rather
  than mis-compiled — but it has not been benchmarked against hand-written
  kernels.
- Every number above came from one machine (MacBook Air M3, 16GB,
  `dev-2026-03:1a5126c6b`). If your results differ, that's a real signal —
  tell us.
