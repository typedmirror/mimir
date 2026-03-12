from typing import Tensor

@gpu
def fused_chain(x: Tensor[float32, 1024], y: Tensor[float32, 1024]) -> Tensor[float32, 1024]:
    a = x + y       # elementwise
    b = a * x       # elementwise (fusible with above)
    c = relu(b)     # elementwise (fusible)
    return c        # should be 1 kernel group, not 3

@gpu
def mixed_dispatch(x: Tensor[float32, 64, 64], w: Tensor[float32, 64, 64]) -> Tensor[float32, 1]:
    z = x @ w       # matmul (2D dispatch)
    a = relu(z)     # elementwise (1D dispatch) — new kernel
    return a.sum()  # reduction — new kernel
    # should be 3 kernel groups: matmul, elementwise, reduction
