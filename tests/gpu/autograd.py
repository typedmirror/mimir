from typing import Tensor

@gpu
def linear(x: Tensor[float32, 64], w: Tensor[float32, 64, 10]) -> Tensor[float32, 10]:
    return x @ w
    # backward: dw = x.T @ grad, dx = grad @ w.T

@gpu
def elementwise_chain(x: Tensor[float32, 64], w: Tensor[float32, 64]) -> Tensor[float32, 64]:
    return sigmoid(x * w)
    # backward: dsigmoid * (w, x) chain rule
