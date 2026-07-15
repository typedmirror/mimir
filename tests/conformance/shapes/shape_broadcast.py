"""Shape validation: numpy-compatible broadcasting rules."""

from mimir.array import zeros

# Valid broadcasts
a = zeros((3, 4))
b = zeros((4,))
c = a + b             # OK: (3,4) + (4,) -> (3,4)

d = zeros((1, 4))
e = a + d             # OK: (3,4) + (1,4) -> (3,4)

# Invalid broadcast — incompatible dimensions
f = zeros((5,))
g = a + f             # E[S002]: cannot broadcast (3,4) and (5,)

h = zeros((3, 5))
i = a + h             # E[S002]: cannot broadcast (3,4) and (3,5)
