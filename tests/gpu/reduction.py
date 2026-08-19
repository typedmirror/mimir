from mimir.array import Tensor, gpu, float32

# Reduction methods — array_check.odin ":sum"/"mean"/"max"/"min" cases. Each
# returns Tensor[T,1] (rank-1, single element), matching the GPU-emitted
# device buffer ABI: single write to result[0], buffer length 1 (see
# docs/FACTORY_CONTRACT_G.md D-G3v2/seam-1). Non-256 sizes included so parity
# (D-G3v2) has more than one size per reduction.

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
