"""GPU autograd: backward pass shape validation."""

from mimir.array import Tensor, gpu, float32

@gpu
def forward(
    x: Tensor[float32, 32, 784],
    w: Tensor[float32, 784, 128],
) -> Tensor[float32, 32, 128]:
    return x @ w
