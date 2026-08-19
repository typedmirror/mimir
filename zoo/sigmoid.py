"""Zoo (Tier 2): sigmoid — elementwise logistic function, method form.

Expression:  y = x.sigmoid()   (= 1 / (1 + exp(-x)) elementwise)

Tolerance: abs 1e-5. A single exp + reciprocal per element, no
accumulation across elements — error is a few ULPs of the underlying
libm exp/div, far under 1e-5.

Runnable-leg convention (zoo/README.md / vector_add.py header): input
from zeros() only, unannotated local. x = zeros(256) -> sigmoid(0) = 0.5
everywhere (the one input value where the exact result is representable
without transcendental rounding, making the expected constant exact).
"""

from mimir.array import Tensor, gpu, float32, zeros


@gpu
def sigmoid(x: Tensor[float32, 256]) -> Tensor[float32, 256]:
    return x.sigmoid()


if __name__ == "__main__":
    x = zeros(256)
    y = sigmoid(x)
    assert y.shape == (256,)
    print("sigmoid: ok, output shape", y.shape)
