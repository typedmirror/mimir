"""Shape validation: matmul inner dimension checking."""

from mimir.array import zeros, matmul

# Valid matmul — inner dimensions match
a = zeros((3, 4))
b = zeros((4, 5))
c = matmul(a, b)  # OK: (3,4) @ (4,5) -> (3,5)

# Invalid matmul — inner dimensions mismatch
d = zeros((5, 6))
e = matmul(a, d)  # E: inner dimensions 4 != 5

# Valid square matmul
f = zeros((3, 3))
g = matmul(f, f)  # OK: (3,3) @ (3,3) -> (3,3)

# 1D @ 2D
h = zeros((4,))
i = matmul(h, b)  # OK: (4,) @ (4,5) -> (5,)

# Invalid 1D @ 2D
j = zeros((3,))
k = matmul(j, b)  # E: inner dimensions 3 != 4
