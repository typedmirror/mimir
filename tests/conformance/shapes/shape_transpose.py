"""Shape validation: transpose shape reversal and chained ops."""

from mimir.array import zeros, matmul, transpose

# Transpose reverses dimensions
a = zeros((3, 4))
b = transpose(a)          # shape becomes (4, 3)

# matmul after transpose — should be valid
c = matmul(a, b)          # OK: (3,4) @ (4,3) -> (3,3)

# matmul of transpose with original — also valid
d = matmul(b, a)          # OK: (4,3) @ (3,4) -> (4,4)
