"""Shape constraints: transpose + matmul chain validation."""

from mimir.array import zeros

# Gradient computation pattern: backward pass uses transposed weights

# Forward: x @ W → (32, 784) @ (784, 128) → (32, 128)
x = zeros((32, 784))
W = zeros((784, 128))
h = x @ W                 # OK

# Backward: grad @ W.T → (32, 128) @ (128, 784) → (32, 784)
grad_h = zeros((32, 128))
Wt = W.T                  # (784, 128).T → (128, 784)
grad_x = grad_h @ Wt      # (32, 128) @ (128, 784) → OK

# Weight gradient: x.T @ grad → (784, 32) @ (32, 128) → (784, 128)
xt = x.T                  # (32, 784).T → (784, 32)
grad_W = xt @ grad_h      # (784, 32) @ (32, 128) → OK

# Error: wrong transpose usage
bad_grad = grad_h @ W     # E: inner dimensions 128 != 784
