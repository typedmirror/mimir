"""Zoo (Tier 2): relu — elementwise rectified linear unit, method form.

Expression:  y = x.relu()   (= max(x, 0) elementwise)

Tolerance: abs 1e-5. relu is a comparison + select, not a rounding-prone
arithmetic op — no floating-point error is introduced beyond the input's
own representation, so 1e-5 absolute holds trivially.

Runnable-leg convention (zoo/README.md / vector_add.py header): inputs from
zeros()/ones() only, unannotated locals. To exercise the clamp-to-zero
branch (the interesting one — the positive branch is identity) the input
is built as `zeros(256) - ones(256)` = -1 everywhere (elementwise
subtraction, not unary negation — D-G1v2 bans `-x`, not `a - b`), so
relu(x) = 0 everywhere.
"""

from mimir.array import Tensor, gpu, float32, zeros, ones


@gpu
def relu(x: Tensor[float32, 256]) -> Tensor[float32, 256]:
    return x.relu()


if __name__ == "__main__":
    x = zeros(256) - ones(256)
    y = relu(x)
    assert y.shape == (256,)
    print("relu: ok, output shape", y.shape)
