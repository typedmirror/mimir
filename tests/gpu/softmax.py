from mimir.array import Tensor, gpu, float32

# .softmax() — method-form activation (D-G1v2 canon: method forms only, no
# free-function activation imports). Exercises array_check.odin's new
# "softmax" case (kills the previously-verified T007: Tensor had no
# .softmax attribute). Two sizes so parity (D-G3v2) has a non-256 case.

@gpu
def softmax_1d(x: Tensor[float32, 256]) -> Tensor[float32, 256]:
    return x.softmax()

@gpu
def softmax_method(x: Tensor[float32, 128]) -> Tensor[float32, 128]:
    return x.softmax()
