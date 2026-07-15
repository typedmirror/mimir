"""Shape constraints: broadcasting validation via + operator on tensors."""

from mimir.array import zeros

# Compatible broadcasting: (3, 4) + (3, 4) → same shape
a = zeros((3, 4))
b = zeros((3, 4))
c = a + b  # OK

# Broadcasting with scalar-like dim: (3, 4) + (1, 4) → (3, 4)
d = zeros((1, 4))
e = a + d  # OK: broadcast dim 0

# Broadcasting with different ranks: (3, 4) + (4,) → (3, 4)
f = zeros((4,))
g = a + f  # OK: right-align and broadcast

# Incompatible shapes: (3, 4) + (3, 5) → error
h = zeros((3, 5))
i = a + h  # E[S002]: incompatible shapes
