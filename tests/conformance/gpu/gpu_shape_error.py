"""GPU integration: shape error caught in @gpu function."""

from mimir.array import Tensor, gpu, float32

@gpu
def bad_matmul(
    x: Tensor[float32, 32, 784],
    w: Tensor[float32, 128, 10],   # WRONG: inner dim 784 != 128
) -> Tensor[float32, 32, 10]:
    return x @ w  # E[GPU011]: shape mismatch (784 != 128)
