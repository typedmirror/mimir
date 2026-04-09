"""GPU: symbolic dimension variables in tensor annotations."""

from mimir.array import Tensor, gpu

@gpu
def matmul_generic(
    x: Tensor[float32, N, K],
    w: Tensor[float32, K, M],
) -> Tensor[float32, N, M]:
    return x @ w
