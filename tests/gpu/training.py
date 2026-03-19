from typing import Tensor

@gpu
def forward_pass(
    x: Tensor[float32, 32, 784],
    w1: Tensor[float32, 784, 128],
    w2: Tensor[float32, 128, 10]
) -> Tensor[float32, 32, 10]:
    h = relu(x @ w1)
    logits = h @ w2
    return softmax(logits)

@gpu
def mlp_step(
    x: Tensor[float32, 16, 64],
    w: Tensor[float32, 64, 32]
) -> Tensor[float32, 16, 32]:
    h = x @ w
    h = relu(h)
    return sigmoid(h)

@gpu
def loss_fn(
    logits: Tensor[float32, 32, 10],
    labels: Tensor[int32, 32]
) -> Tensor[float32, 1]:
    return cross_entropy(logits, labels)
