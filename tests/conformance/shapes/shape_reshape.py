"""Shape validation: reshape element count conservation."""

from mimir.array import zeros, reshape

a = zeros((3, 4))

# Valid reshapes — total elements preserved
b = reshape(a, (2, 6))   # OK: 3*4 = 12 = 2*6
c = reshape(a, (12,))    # OK: 12 = 12
d = reshape(a, (4, 3))   # OK: 12 = 12
e = reshape(a, (1, 12))  # OK: 12 = 12

# Invalid reshape — element count mismatch
f = reshape(a, (2, 5))   # E[SHAPE002]: 12 != 10
g = reshape(a, (3, 5))   # E[SHAPE002]: 12 != 15
