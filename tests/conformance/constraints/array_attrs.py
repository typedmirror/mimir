from typing import assert_type
from mimir.array import zeros, array, ones

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
sm = a.sum()
assert_type(sm, float)
mn = a.mean()
assert_type(mn, float)
mx = a.max()
assert_type(mx, float)
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
