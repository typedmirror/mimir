"""Shape constraints: neural network forward pass pattern."""

from mimir.array import zeros

# Mini neural network: input → linear → linear → output
# Shapes must be consistent through the chain

# Layer weights
w1 = zeros((784, 128))   # input→hidden
b1 = zeros((128,))       # hidden bias
w2 = zeros((128, 10))    # hidden→output
b2 = zeros((10,))        # output bias

# Forward pass with batch of 32 images
x = zeros((32, 784))     # batch input

h = x @ w1               # OK: (32, 784) @ (784, 128) → (32, 128)
h = h + b1               # OK: (32, 128) + (128,) → broadcast

out = h @ w2              # OK: (32, 128) @ (128, 10) → (32, 10)
out = out + b2            # OK: (32, 10) + (10,) → broadcast

# Shape error: wrong weight matrix dimensions
w_bad = zeros((64, 10))
bad = h @ w_bad           # E: inner dimensions 128 != 64
