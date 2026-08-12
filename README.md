# Mimir

> Write GPU kernels in typed Python. Prove them correct before they run. Ship them as bare Metal/WebGPU files — no runtime attached.

Everyone doing ML in Python eventually hits a shape mismatch twenty minutes into a run. And writing a custom GPU kernel means CUDA C++, or Triton — which needs an NVIDIA card and a live PyTorch runtime. Mimir is a compiler: it takes a typed Python subset, statically proves shapes, dtypes, and device placement, and emits a standalone Metal or WebGPU kernel — a file you can vendor into any repo, with no Python attached at runtime.

One native binary. Written in [Odin](https://odin-lang.org/), 67K lines, zero dependencies, its own Python parser — no CPython anywhere in the toolchain.

## Sixty seconds

This is a complete mimir kernel — it's ordinary typed Python:

```python
from mimir.array import Tensor, gpu, float32

@gpu
def linear_forward(
    x: Tensor[float32, 32, 784],
    w: Tensor[float32, 784, 128],
    b: Tensor[float32, 128],
) -> Tensor[float32, 32, 128]:
    h = x @ w        # (32,784) @ (784,128) → (32,128)
    return h + b     # (32,128) + (128,) → broadcast
```

**Run it as plain Python** (debugging — `mimir.array` ships as a ~350-line zero-dependency shim, so you can set breakpoints and print shapes):

```
$ PYTHONPATH=python python3 tests/gpu/shape_integration.py
$ echo $?
0
```

**Prove it** (types, shapes, dtypes, devices, bounds — statically, before anything runs):

```
$ mimir check tests/gpu/shape_integration.py
  checked tests/gpu/shape_integration.py (3 stmts, 166 symbols, 3 scopes, 4 blocks, 0 guards, 1333 types)
mimir: successfully checked 1 file(s)
```

**Compile it** (a bare `.metal` file — no runtime, no framework, vendor it anywhere):

```
$ mimir compile-gpu tests/gpu/shape_integration.py --backend msl
#include <metal_stdlib>
using namespace metal;

kernel void kernel_linear_forward(
    device const float* param_x [[buffer(0)]],
    ...
```

Same file, `--backend wgsl` for the browser.

## And when the kernel is wrong

```python
@gpu
def bad_matmul(
    x: Tensor[float32, 32, 784],
    w: Tensor[float32, 128, 10],   # inner dim 784 != 128
) -> Tensor[float32, 32, 10]:
    return x @ w
```

```
$ mimir check tests/fixtures/trust_t1/gpu_shape/bad_matmul.py
tests/fixtures/trust_t1/gpu_shape/bad_matmul.py:10:11: error[GPU011]: matmul shape mismatch: left has K=784, right has K=128
  why: matrix multiplication requires inner dimensions to match (A[M,K] @ B[K,N])
  fix: ensure the inner dimensions of both matrices are equal
```

That's the moment mimir exists for: the twenty-minutes-into-a-run crash, moved to before the run.

## How dual execution works

`@gpu` marks a function as carrying a proof obligation. The same file runs two ways:

- **Interpreted**: `python/mimir/array.py` is a pure-Python shim (`gpu` is an identity decorator; `Tensor` is a flat-buffer wrapper with broadcasting ops). Debug with normal Python tools.
- **Compiled**: `mimir check` + `mimir compile-gpu` never read `python/` — `mimir.array` resolves against a virtual module baked into the checker. Checker output is byte-identical whether or not `python/` exists on disk.

Triton and JAX/Pallas kernels need a live runtime and a real GPU to execute at all. A mimir kernel is plain Python first; the compiled artifact is the same logic with the runtime subtracted.

## Also in the binary

The kernel verifier sits on a full Python static analyzer (native parser → binder → flow analysis → type checker), because proving a kernel requires understanding the Python around it. `mimir check` works on ordinary Python projects — ~170 diagnostic codes across types, flow, lint, and security, an LSP server (`mimir lsp`), and more. Other subcommands (format, test, audit, deps, …) exist at varying maturity; `check`, `compile-gpu`, and `lsp` are the supported surface.

## Status — honest table

| | State |
|---|---|
| Shape/dtype/device proofs for `@gpu` kernels (matmul, broadcast, elementwise, reductions) | Works today, gated by tests |
| MSL + WGSL emission | Works today (demo above) |
| PTX / SPIR-V emission | Elementwise only — kernels the backend can't emit correctly are refused loudly, never mis-compiled |
| Dual execution (CPython shim) | Works today |
| Analyzer on ordinary Python | Works today; crash-free on every corpus we've thrown at it |
| PyTorch shape checking | Early — torch tensors are currently shape-erased; on the roadmap |
| Kernel zoo, browser demo, benchmark table | Not built yet |
| General PEP typing conformance | **Not a goal.** On the official `python/typing` suite mimir scores 15.0% line-level — and 0 crashes / 0 timeouts across all 141 files. It is a tensor/kernel checker, not a mypy replacement. Reproducible: `tests/scripts/official_typing_scorecard.py`. Full method + numbers in [RECEIPTS.md](RECEIPTS.md). |

Every number in this README reproduces from a clean build — the test harness fails if a diagnostic code stops firing. [RECEIPTS.md](RECEIPTS.md) walks you through verifying all of it in ~20 minutes.

## Build

Requires the [Odin compiler](https://odin-lang.org/) and Python 3 (for the test scripts only).

```bash
git clone https://github.com/typedmirror/mimir && cd mimir
odin build src/ -collection:mimir=src/ -out:mimir -o:speed   # ~22s on an M3 Air
./mimir check your_kernel.py
```

To run the test gates yourself: `cp mimir mimir_bin` first (the test scripts
invoke `./mimir_bin`), then follow [RECEIPTS.md](RECEIPTS.md).

Zero configuration, no virtual environments. Optional `mimir.toml` if you want it.

## Why

> I started this because I wanted to learn type system development, and figured: people keep doing GPU work from Python — why not build an actual compiler for it? Honestly, it was a for-fun project because I needed something outside my comfort zone. It got out of hand.

## License

MIT
