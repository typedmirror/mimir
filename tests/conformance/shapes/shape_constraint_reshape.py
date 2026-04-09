"""Shape constraints: reshape element count validation."""

from mimir.array import zeros

a = zeros((4, 6))

# Valid reshape: 4*6 = 24 = 2*12
b = a.reshape(2, 12)     # OK: 24 elements → 24 elements

# Valid reshape: flatten
c = a.reshape(24)         # OK: 24 → 24

# Invalid reshape: element count mismatch (4*6=24 ≠ 5*5=25)
d = a.reshape(5, 5)       # E: reshape element count
