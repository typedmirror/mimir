"""GPU tensor types: Tensor annotations and shape checking"""
from mimir.array import Tensor, gpu, float32
@gpu
def tensor_add(a: Tensor[float32, 8, 8], b: Tensor[float32, 8, 8]) -> Tensor[float32, 8, 8]:
    return a + b

@gpu
def tensor_matmul(a: Tensor[float32, 4, 3], b: Tensor[float32, 3, 5]) -> Tensor[float32, 4, 5]:
    return a @ b

@gpu
def tensor_chain(x: Tensor[float32, 16]) -> Tensor[float32, 16]:
    a = x + x
    b = a * x
    c = b - a
    return c

@gpu
def tensor_negate(x: Tensor[float32, 32]) -> Tensor[float32, 32]:
    return -x

@gpu
def tensor_reduce(x: Tensor[float32, 32, 32]) -> Tensor[float32, 1]:
    return sum(x)

@gpu
def tensor_transpose(x: Tensor[float32, 3, 5]) -> Tensor[float32, 5, 3]:
    return x.T
