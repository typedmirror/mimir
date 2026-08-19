# Kernel zoo

A small, curated set of GPU kernels, each a standalone `.py` file under
`zoo/`, written against mimir's canonical `mimir.array` surface
(`from mimir.array import Tensor, gpu, float32, ...`). Every entry:

- checks clean under `mimir check`,
- compiles clean (exit 0, no refusals) via `mimir compile-gpu --backend msl`
  and `--backend wgsl`,
- runs directly under CPython via the pure-Python shim
  (`PYTHONPATH=python python3 zoo/<entry>.py`),
- carries a docstring stating the exact expression it computes and its
  parity tolerance (with derivation for anything beyond a single
  elementwise op).

**Canon (ruling D-G1v2, Phase G Wave 1):** METHOD forms only (`x.relu()`,
`x.sum()`) — no free-function activation/reduction imports (they shadow
builtins and are the Any-typed anti-pattern this canon exists to ban), no
unary tensor negation (`-x` is unsupported, emits T005), no `Any`-typed
surfaces anywhere in an entry.

**Runnable-leg convention** (established here for lane L2's parity harness
to mirror): each entry's `if __name__ == "__main__":` block builds
deterministic inputs from `zeros()`/`ones()` only — the two `mimir.array`
creation functions implemented identically in both the pure-Python shim
(`python/mimir/array.py`) and the checker's virtual module
(`src/checker/virtual_modules.odin`). `randn()` exists in the shim but is
**not** exported by the checker's virtual module, so importing it into a
file that must also `mimir check` clean either trips a T001 (explicit
annotation vs. the shape-erased creation-function return type) or silently
resolves to an unchecked name with no diagnostic (no B003 fires for an
unresolved *name* inside an already-resolved virtual module) — neither is
an honest "checks clean." `zeros()`/`ones()` avoid both failure modes:
assign their result to an **unannotated** local (checker infers permissively
through the shape-erased creation-function return, matching the same
erasure convention documented for the torch virtual modules; an explicit
`x: Tensor[float32, N] = zeros(N)` annotation trips T001 for the same
distinct-erased-Type_ID reason and must be avoided). Every Tier-1 entry
below was verified to check clean, shim-run clean, and produce the exact
constant its derivation predicts (e.g. `vector_add(ones, ones) == 2`
everywhere).

## Tier 1 — green today

| Kernel | Expression | Tolerance (derivation) | Backends |
|---|---|---|---|
| `vector_add` | `z = x + y` | abs 1e-5 — single float32 add, no accumulation | check clean · MSL emit clean · WGSL emit clean · shim-verified |
| `linear_forward` | `h = x @ w; return h + b` (broadcast) | abs 1e-5 — K=64 accumulated multiply-adds + one broadcast add, well under tol at this K | check clean · MSL emit clean · WGSL emit clean · shim-verified |
| `matmul` | `c = a @ b` | abs 1e-5 — K=16 accumulated multiply-adds | check clean · MSL emit clean · WGSL emit clean · shim-verified |
| `squared_error` | `e = (pred - target) * (pred - target)` (elementwise, no reduction) | abs 1e-5 — two elementwise ops, no accumulation | check clean · MSL emit clean · WGSL emit clean · shim-verified |

MSL emission for `linear_forward` was spot-checked: 2D dispatch mode
(`gid`/`row`/`col`), no orphan `tid`, bias broadcast correctly indexed
`param_b[col]` (len-N broadcast against an (M,N) kernel) — the exact
pattern `gpu_emit_backend_test.py` guards permanently.

Renamed from an earlier `mse_loss` draft to `squared_error`: a `.mean()`
reduction is a Tier-2 concern (the 1D reducer needs D-G3v2's size-general
fix first), so this entry stays purely elementwise to be green in Tier 1.

## Tier 2 — green (gates fired: L1 merged, D-G3v2 merged, D-G4v2 (c)/(e)/(f)
merged, L2 green on Tier 1 — all four confirmed at main @ a377f90)

### Reduction/softmax size bound

All reduction and softmax entries use **N ≤ 256** — `GPU_REDUCTION_BLOCK_BOUND`
(src/gpu/emit.odin). This is a ruled contract term for the zoo, not a hard
system ceiling: D-G3v2's size-general fix supports two-pass reduction for
N > 256 in general, but every wave-1 zoo reduction/softmax entry stays
within the single-workgroup bound so each compiles to **exactly one
256-thread threadgroup** (tail-guarded tree reduction, single write to
`result[0]`) — sizes above the bound refuse loudly by design rather than
silently truncating. The parity harness must dispatch these five kernels
as one 256-thread group, not a grid.

| Kernel | Expression | Tolerance (derivation) | Backends |
|---|---|---|---|
| `relu` | `y = x.relu()` | abs 1e-5 — comparison + select, no rounding-prone arithmetic | check clean · MSL emit clean · WGSL emit clean · shim-verified |
| `sigmoid` | `y = x.sigmoid()` | abs 1e-5 — one exp + reciprocal per element, no accumulation | check clean · MSL emit clean · WGSL emit clean · shim-verified |
| `elementwise_math` | `x.exp().log().sqrt().abs()` | abs 1e-5 — four chained elementwise ops, well-conditioned at O(1) magnitudes, no cross-element accumulation | check clean · MSL emit clean · WGSL emit clean · shim-verified |
| `saxpy` | `z = a * x + y` (`a`: `Tensor[float32,1]`, 1D scalar broadcast `[0]`) | abs 1e-5 — one scalar-broadcast multiply + one elementwise add, no accumulation | check clean · MSL emit clean · WGSL emit clean · shim-verified |
| `sum_reduce` | `y = x.sum()` → `Tensor[float32,1]` | RELATIVE 3.05e-5 = N·ε_f32, N=256, ε_f32=2⁻²³≈1.1920929e-7 | check clean · MSL emit clean (1×256-thread threadgroup) · WGSL emit clean · shim-verified |
| `max_reduce` | `y = x.max()` → `Tensor[float32,1]` | RELATIVE 3.05e-5 = N·ε_f32 (stated for convention consistency; a comparison-tree accumulates no rounding error in practice) | check clean · MSL emit clean (1×256-thread threadgroup) · WGSL emit clean · shim-verified |
| `mean` | `y = x.mean()` → `Tensor[float32,1]` | RELATIVE 3.05e-5 = N·ε_f32 — sum-tree dominates, final divide-by-N adds one negligible rounding step | check clean · MSL emit clean (1×256-thread threadgroup) · WGSL emit clean · shim-verified |
| `mse_loss` | `((pred-target)*(pred-target)).mean()` → `Tensor[float32,1]` | RELATIVE 3.05e-5 = N·ε_f32 — sum-tree inside `.mean()` dominates over the elementwise sub+mul feeding it | check clean · MSL emit clean (1×256-thread threadgroup) · WGSL emit clean · shim-verified |
| `softmax` | `y = x.softmax()` | RELATIVE 3.05e-5 = N·ε_f32 — two N-term reductions (max-reduce, sum-of-exp) dominate | check clean · MSL emit clean (1×256-thread threadgroup, barrier confirmed between the max-reduce read of `sm[0]` and the exp-overwrite — D-G4v2(e)) · WGSL emit clean · shim-verified |

All nine entries verified: `mimir check` clean, `compile-gpu --backend msl`
and `--backend wgsl` both exit 0 with no refusals, `PYTHONPATH=python
python3 zoo/<entry>.py` exits 0 with output matching the derivation exactly
(e.g. `sum_reduce(ones(256)) == 256.0`, `softmax(ones(256))[0] == 1/256`).
`softmax`'s emitted MSL was spot-checked for the D-G4v2(e) barrier: a
`threadgroup_barrier` sits between `sm_max = sm[0]` and the following
exp-overwrite of `sm[tid]` — the fix for the read/overwrite data race.
Parity is corroboration of that fix, not proof of race-freedom (the
both-directions barrier fixture landed by D-G4v2(e) is the proof —
candor's trail confirms extraction (f) needed no code fix, only fixtures).

`elementwise_math`: unlocked by L1 seam (5) — `.exp()/.log()/.sqrt()/.abs()`
now exist as precise same-shape/dtype Tensor→Tensor methods
(src/checker/array_check.odin), so this entry no longer needs the
Any-typed free-function imports the D-G1v2 canon bans (N1, resolved).

`saxpy`: unlocked by D-G4v2(c) — 1D param broadcast now classifies a
length-1 param as `[0]` (scalar broadcast) against a length-N kernel's
`[tid]`, refusing any other length loudly (B2, resolved).

`mse_loss`: composes `zoo/squared_error.py`'s elementwise formula (inlined,
not imported — each zoo entry is a standalone file) with `.mean()`, now
that D-G3v2's size-general reducer fix makes reductions correct at N=256
(real N in the kernel, guarded tails, mean divides by actual N, single
write to `result[0]`).

Out of wave 1 entirely (unchanged from the contract): layernorm, attention,
scan, MLP-as-fused, quantization.

## Parity status — G1 wave (2026-08-19, independently verified)

All thirteen entries executed on-device (Apple M3, MSL compiled at runtime
via the Metal framework) and compared against the CPU reference (interpreted
shim) with seeded inputs:

| kernel | MSL executed (Apple M3) | max |Δ| |
|---|---|---|
| vector_add | PASS | 0.0e+00 |
| linear_forward | PASS | 0.0e+00 |
| matmul | PASS | 0.0e+00 |
| squared_error | PASS | 0.0e+00 |
| relu | PASS | 0.0e+00 |
| sigmoid | PASS | 0.0e+00 |
| elementwise_math | PASS | 0.0e+00 |
| saxpy | PASS | 0.0e+00 |
| sum_reduce | PASS | 0.0e+00 |
| max_reduce | PASS | 0.0e+00 |
| mean | PASS | 0.0e+00 |
| mse_loss | PASS | 0.0e+00 |
| softmax | PASS | 0.0e+00 |

Reproduce: `python3 tests/scripts/kernel_parity_test.py` (builds nothing itself;
needs `mimir_bin` and `tests/tools/metal_run_bin` — see the harness header).
The harness is mutation-proven both ways: a deliberately broken elementwise
kernel (+→−) and a wrong-divisor reduction mutation each report FAIL.

Honesty note: during this wave the harness caught a real compiler bug in
production use — `elementwise_math` initially FAILED parity (max |Δ| = 1.0)
because the method-form `.abs()` was silently dropped during graph extraction,
emitting a kernel that computed nothing while exiting 0. The fix (plus a new
GPU015 loud refusal for ANY unknown tensor method, closing the class) landed
before this table went green. Static checks alone did not and could not catch
it; on-device numerical parity did. That is why this harness exists.
