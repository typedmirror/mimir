"""Zoo (Tier 1): linear_forward — matmul + 1D-broadcast bias add.

Expression:  h = x @ w
             return h + b        # (16,32) + (32,) -> broadcast over rows

Tolerance: abs 1e-5. Each output element accumulates K=64 float32
multiply-adds (matmul) plus one broadcast add. Worst-case accumulated
rounding error for K=64 terms of this magnitude is orders of magnitude
below 1e-5, so a flat absolute tolerance holds.

Runnable-leg convention (see zoo/README.md and vector_add.py's header for
the full rationale): deterministic inputs from zeros()/ones() only (the
creation functions common to both the shim and the checker's virtual
module). x=ones(16,64), w=ones(64,32) -> h = 64 everywhere (sum of 64
ones*ones); b=ones(32) -> result = 65 everywhere.
"""

from mimir.array import Tensor, gpu, float32, ones


@gpu
def linear_forward(
    x: Tensor[float32, 16, 64],
    w: Tensor[float32, 64, 32],
    b: Tensor[float32, 32],
) -> Tensor[float32, 16, 32]:
    h = x @ w
    return h + b


if __name__ == "__main__":
    x = ones(16, 64)
    w = ones(64, 32)
    b = ones(32)
    out = linear_forward(x, w, b)
    assert out.shape == (16, 32)
    print("linear_forward: ok, output shape", out.shape)
