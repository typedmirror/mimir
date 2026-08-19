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

## Tier 2 — PENDING (hard-gated, per D-G1v2 / lane L3 acceptance)

Gate: **L1 merged AND D-G3v2 merged AND D-G4v2 (c)/(e)/(f) merged AND L2
green on Tier 1.** None of the four gates has fired yet as of this wave;
no Tier-2 entry is authored, even speculatively.

| Kernel | Expression (planned) | Blocked on |
|---|---|---|
| `relu` | `x.relu()` | L1 (method case, TYPE_ANY-free typing) |
| `sigmoid` | `x.sigmoid()` | L1 (method case, TYPE_ANY-free typing) |
| `elementwise_math` | `x.exp()` / `.log()` / `.sqrt()` / `.abs()` chains | L1 seam (5) — method forms don't exist yet; N1 moved this out of Tier 1 because its old green route was the Any-typed free-function imports this canon bans |
| `saxpy` | `a * x + y` (scalar-vector-add via 1D param broadcast) | D-G4v2(c) — 1D param broadcast refusal/correctness |
| `sum_reduce` | `x.sum()` | D-G3v2 — size-general reducer fix (current 1D reducer is wrong: 256-hardcoded, `.Mean` divides by literal 256, broadcasts garbage N-wide instead of writing once to `result[0]`) |
| `max_reduce` | `x.max()` | D-G3v2 (same reducer fix) |
| `mean` | `x.mean()` | D-G3v2 (same reducer fix) |
| `mse_loss` | `squared_error(pred, target).mean()` | D-G3v2 (reduction) — composes on top of `squared_error` once reductions are size-general |
| `softmax` | `x.softmax()` | D-G4v2(e) — inline-reduce barrier fix (data race between reading `sm[0]` and the exp-overwrite) + D-G3v2 size-generalization; D-G4v2(f) — method-form activation extraction must be proven (not just typed) before `.softmax()`/`.relu()`/etc. are trusted to compile to a real op node |

Out of wave 1 entirely (unchanged from the contract): layernorm, attention,
scan, MLP-as-fused, quantization.
