"""Zoo (Tier 2): mse_loss — squared_error + .mean() reduction.

Expression:  diff = pred - target
             sq   = diff * diff
             return sq.mean()          -> Tensor[float32, 1]

Composes zoo/squared_error.py's elementwise formula with the reduction
this canon gates behind D-G3v2 (squared_error itself stays Tier-1 and
reduction-free — see its docstring). N = 256 (single-workgroup bound —
see zoo/README.md). Dispatch requirement: exactly one 256-thread
threadgroup for the mean's internal sum-tree, single write to result[0].

Tolerance: RELATIVE 3.05e-5, derived as N * eps_f32 with N=256 and
eps_f32 = 2^-23 ~= 1.1920929e-7 (dominant term is the N-term sum inside
.mean(); the elementwise sub+mul feeding it contribute only a couple of
ULPs per element, negligible next to the accumulation term).

Runnable-leg convention: inputs from ones()/zeros() only, unannotated
locals. pred = ones(256), target = zeros(256) -> diff = 1, sq = 1,
mean = 1.0 exactly. Result index [0].
"""

from mimir.array import Tensor, gpu, float32, ones, zeros


@gpu
def mse_loss(
    pred: Tensor[float32, 256],
    target: Tensor[float32, 256],
) -> Tensor[float32, 1]:
    diff = pred - target
    sq = diff * diff
    return sq.mean()


if __name__ == "__main__":
    pred = ones(256)
    target = zeros(256)
    y = mse_loss(pred, target)
    assert y.shape == (1,)
    assert y.data[0] == 1.0
    print("mse_loss: ok, output", y.data[0])
