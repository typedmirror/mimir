"""Zoo (Tier 1): matmul — plain 2D matrix multiplication, no bias.

Expression:  c = a @ b

Tolerance: abs 1e-5. Each output element accumulates K=16 float32
multiply-adds. Worst-case accumulated rounding error for K=16 terms of this
magnitude is far below 1e-5, so a flat absolute tolerance holds.

Runnable-leg convention (see zoo/README.md / vector_add.py header):
deterministic inputs from ones() only. a=ones(8,16), b=ones(16,32) ->
c = 16 everywhere (sum of 16 ones*ones, K=16).
"""

from mimir.array import Tensor, gpu, float32, ones


@gpu
def matmul(
    a: Tensor[float32, 8, 16],
    b: Tensor[float32, 16, 32],
) -> Tensor[float32, 8, 32]:
    return a @ b


if __name__ == "__main__":
    a = ones(8, 16)
    b = ones(16, 32)
    c = matmul(a, b)
    assert c.shape == (8, 32)
    print("matmul: ok, output shape", c.shape)
