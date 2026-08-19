"""Zoo (Tier 2): sum_reduce — full-array sum reduction, method form.

Expression:  y = x.sum()   -> Tensor[float32, 1] (single write to result[0])

N = 256 (the single-workgroup bound — see "Reduction/softmax size bound"
in zoo/README.md; D-G3v2's size-general fix supports larger N via a
two-pass scheme in general, but wave-1 zoo entries stay within the
single-group bound by ruled contract term). Dispatch requirement: the
emitted MSL/WGSL kernel requires EXACTLY ONE 256-thread threadgroup
(tail-guarded tree reduction, `threadgroup float sh[256]`,
`if (tid == 0) result[0] = ...` — single write, never a per-thread
broadcast) — the parity harness must dispatch it that way.

Tolerance: RELATIVE 3.05e-5, derived as N * eps_f32 with N=256 and
eps_f32 = 2^-23 ~= 1.1920929e-7 (the standard worst-case error bound for
a naive N-term float32 accumulation).

Runnable-leg convention (zoo/README.md / vector_add.py header): input
from ones() only, unannotated local. x = ones(256) -> sum = 256.0 exactly
(sum of 256 ones has no rounding error at all, but the kernel still
exercises the full tree-reduction code path). Result index [0].
"""

from mimir.array import Tensor, gpu, float32, ones


@gpu
def sum_reduce(x: Tensor[float32, 256]) -> Tensor[float32, 1]:
    return x.sum()


if __name__ == "__main__":
    x = ones(256)
    y = sum_reduce(x)
    assert y.shape == (1,)
    assert y.data[0] == 256.0
    print("sum_reduce: ok, output", y.data[0])
