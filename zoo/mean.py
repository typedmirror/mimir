"""Zoo (Tier 2): mean — full-array mean reduction, method form.

Expression:  y = x.mean()   -> Tensor[float32, 1] (single write to result[0])

N = 256 (single-workgroup bound — see zoo/README.md). Dispatch
requirement: exactly one 256-thread threadgroup (sum-tree reduction over
the actual element count N, then divide by N — not a hardcoded divisor;
see D-G3v2).

Tolerance: RELATIVE 3.05e-5, derived as N * eps_f32 with N=256 and
eps_f32 = 2^-23 ~= 1.1920929e-7 (sum accumulation dominates; the final
divide-by-N adds one more rounding step, negligible next to the N-term
sum).

Runnable-leg convention: input from ones() only, unannotated local.
x = ones(256) -> mean = 256/256 = 1.0 exactly. Result index [0].
"""

from mimir.array import Tensor, gpu, float32, ones


@gpu
def mean(x: Tensor[float32, 256]) -> Tensor[float32, 1]:
    return x.mean()


if __name__ == "__main__":
    x = ones(256)
    y = mean(x)
    assert y.shape == (1,)
    assert y.data[0] == 1.0
    print("mean: ok, output", y.data[0])
