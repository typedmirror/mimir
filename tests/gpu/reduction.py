from mimir.array import Tensor, gpu, float32

@gpu
def sum_reduce(x: Tensor[float32, 1024]) -> Tensor[float32, 1]:
    return x.sum()

@gpu
def mean_reduce(x: Tensor[float32, 256]) -> Tensor[float32, 1]:
    return x.mean()

@gpu
def max_reduce(x: Tensor[float32, 512]) -> Tensor[float32, 1]:
    return x.max()

@gpu
def min_reduce(x: Tensor[float32, 512]) -> Tensor[float32, 1]:
    return x.min()
