"""Shape validation: shape inference from creation functions."""

from mimir.array import zeros, ones, arange, matmul, reshape

# Multi-dimensional creation
a = zeros((2, 3, 4))
b = ones((5,))
c = arange(0, 10)       # shape (10,)

# Use shapes in operations
d = zeros((3, 4))
e = zeros((4, 2))
f = matmul(d, e)        # OK: (3,4) @ (4,2) -> (3,2)

# Reshape valid chain
g = reshape(f, (6,))    # OK: 3*2 = 6
h = reshape(f, (2, 3))  # OK: 6 = 6
