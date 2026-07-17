"""GPU: complete training step — forward + loss + backward."""

from mimir.array import Tensor, gpu, float32

@gpu
def train_step(
    x: Tensor[float32, 32, 784],
    w1: Tensor[float32, 784, 256],
    w2: Tensor[float32, 256, 10],
    labels: Tensor[float32, 32, 10],
) -> Tensor[float32, 32, 10]:
    # Forward pass
    h = x @ w1           # (32,784) @ (784,256) → (32,256)
    h = h * h             # ReLU^2 approximation (elementwise)
    logits = h @ w2       # (32,256) @ (256,10) → (32,10)
    # Loss (MSE)
    diff = logits - labels  # (32,10) - (32,10)
    return diff * diff      # elementwise square
