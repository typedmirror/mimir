from typing import assert_type
from mimir.array import zeros, arange

# 1D indexing → element
a = arange(0, 10)
x = a[0]
assert_type(x, int)

# 2D indexing → sub-tensor or element
b = zeros((3, 4))
row = b[0]  # row is sub-tensor

# Slice → tensor
sliced = a[0:5]

# Type error: tensor not assignable to str
t = zeros((2, 2))
s: str = t  # E[T001]: Incompatible types
