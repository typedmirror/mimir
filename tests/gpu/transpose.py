from typing import Tensor

@gpu
def transpose_mat(x: Tensor[float32, 64, 64]) -> Tensor[float32, 64, 64]:
    return x.T

@gpu
def transpose_method(x: Tensor[float32, 32, 16]) -> Tensor[float32, 16, 32]:
    return x.transpose()
