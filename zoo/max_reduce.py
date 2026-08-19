"""Zoo (Tier 2): max_reduce — full-array max reduction, method form.

Expression:  y = x.max()   -> Tensor[float32, 1] (single write to result[0])

N = 256 (single-workgroup bound — see zoo/README.md). Dispatch
requirement: exactly one 256-thread threadgroup (same tail-guarded tree
pattern as sum_reduce, comparison-tree instead of add-tree, single write
to result[0]).

Tolerance: RELATIVE 3.05e-5, derived as N * eps_f32 with N=256 and
eps_f32 = 2^-23 ~= 1.1920929e-7 — stated for consistency with the other
reduction entries' convention, though a max/min tree does not actually
accumulate rounding error (each step is a comparison, not an arithmetic
combine), so real-world error is 0.

Runnable-leg convention: input from ones() only, unannotated local.
x = ones(256) -> max = 1.0 exactly. Result index [0].
"""

from mimir.array import Tensor, gpu, float32, ones


@gpu
def max_reduce(x: Tensor[float32, 256]) -> Tensor[float32, 1]:
    return x.max()


if __name__ == "__main__":
    x = ones(256)
    y = max_reduce(x)
    assert y.shape == (1,)
    assert y.data[0] == 1.0
    print("max_reduce: ok, output", y.data[0])
