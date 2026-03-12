from typing import Tensor

@gpu
def multi_buffer(a: Tensor[float32, 1024], b: Tensor[float32, 1024],
                 c: Tensor[float32, 1024]) -> Tensor[float32, 1024]:
    t1 = a + b       # intermediate: 4096 bytes
    t2 = t1 * c      # intermediate: 4096 bytes, t1 dead after this
    return t2         # t1 buffer reusable

@gpu
def simple_chain(x: Tensor[float32, 256]) -> Tensor[float32, 256]:
    a = relu(x)
    b = sigmoid(a)
    return b
