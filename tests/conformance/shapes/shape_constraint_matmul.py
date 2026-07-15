"""Shape constraints: matmul via @ operator on tensor values."""

from mimir.array import zeros

# Direct @ operator — triggers Shape_Matmul constraint
a = zeros((3, 4))
b = zeros((4, 5))
c = a @ b  # OK: (3,4) @ (4,5) -> (3,5)

# Elementwise on tensors
d = a + a  # OK: same shapes

# Invalid matmul — inner dimensions mismatch (caught by shape pass)
e = zeros((5, 6))
f = a @ e  # E[S001]: inner dimensions 4 != 5
