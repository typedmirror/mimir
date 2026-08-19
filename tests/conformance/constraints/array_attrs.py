from typing import assert_type
from mimir.array import zeros, array, ones, Tensor

a = zeros((3, 4))

# Properties
s = a.shape
assert_type(s, tuple)
n = a.ndim
assert_type(n, int)
d = a.dtype
assert_type(d, str)
sz = a.size
assert_type(sz, int)

# Transpose property
t = a.T

# Methods
flat = a.flatten()
r = a.reshape((12,))
# sum/mean/max now return Tensor[T,1] (rank-1, single element) — the
# GPU-emitted reduction ABI (docs/FACTORY_CONTRACT_G.md D-G3v2/seam-1),
# not a bare scalar. Semantic change recorded in DECISIONS (S-G1).
sm = a.sum()
assert_type(sm, Tensor[float, 1])
mn = a.mean()
assert_type(mn, Tensor[float, 1])
mx = a.max()
assert_type(mx, Tensor[float, 1])
ami = a.argmin()
assert_type(ami, int)

# Copy / conversion
c = a.copy()
lst = a.tolist()
assert_type(lst, list)
itm = a.item()
assert_type(itm, float)

# Boolean methods
b = a.any()
assert_type(b, bool)
