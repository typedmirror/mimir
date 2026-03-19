from typing import Tensor

@gpu
def softmax_1d(x: Tensor[float32, 256]) -> Tensor[float32, 256]:
    return softmax(x)

@gpu
def softmax_method(x: Tensor[float32, 128]) -> Tensor[float32, 128]:
    return x.softmax()
