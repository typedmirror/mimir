"""GPU integration: shapes from annotations → compute graph → validated kernel."""

from mimir.array import Tensor, gpu, float32

@gpu
def linear_forward(
    x: Tensor[float32, 32, 784],
    w: Tensor[float32, 784, 128],
    b: Tensor[float32, 128],
) -> Tensor[float32, 32, 128]:
    h = x @ w        # (32,784) @ (784,128) → (32,128)
    return h + b      # (32,128) + (128,) → broadcast
