from typing import Tensor

@gpu
def simple_conv(
    x: Tensor[float32, 1, 3, 32, 32],
    w: Tensor[float32, 16, 3, 3, 3]
) -> Tensor[float32, 1, 16, 30, 30]:
    return conv2d(x, w)

@gpu
def conv_relu_pool(
    x: Tensor[float32, 1, 3, 28, 28],
    w: Tensor[float32, 8, 3, 5, 5]
) -> Tensor[float32, 1, 8, 12, 12]:
    h = conv2d(x, w)
    h = relu(h)
    return max_pool2d(h)

@gpu
def conv_flatten_linear(
    x: Tensor[float32, 1, 1, 8, 8],
    conv_w: Tensor[float32, 4, 1, 3, 3],
    fc_w: Tensor[float32, 144, 10]
) -> Tensor[float32, 1, 10]:
    h = conv2d(x, conv_w)
    h = relu(h)
    h = flatten(h)
    return h @ fc_w
