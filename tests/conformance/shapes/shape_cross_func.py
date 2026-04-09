"""Shape constraints: cross-function shape propagation."""

from mimir.array import zeros

def matmul_check(a, b):
    """Inner function that does matmul — shapes flow from caller."""
    return a @ b

# Valid call — shapes propagate through
x = zeros((32, 784))
w = zeros((784, 128))
result = matmul_check(x, w)  # OK: (32,784) @ (784,128)
