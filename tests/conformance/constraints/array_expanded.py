from typing import assert_type
from mimir.array import (
    eye, full, empty, concatenate, stack, split,
    squeeze, expand_dims, flatten, max, min, argmax, argmin,
    cumsum, allclose, isnan, isinf, where, clip, abs, sqrt, exp, log,
    zeros,
)

a = zeros((3, 4))

# Creation
e = eye(3)
f = full((2, 2), 1.0)
em = empty((5,))

# Reductions
mx = max(a)
mn = min(a)
amx = argmax(a)
# argmax returns Tensor[int] (not scalar) — no assert_type needed
cs = cumsum(a)

# Manipulation
sq = squeeze(a)
ed = expand_dims(a, axis=0)
fl = flatten(a)
parts = split(a, 2)
assert_type(parts, list)

# Comparison
close = allclose(a, a)
assert_type(close, bool)
nan_mask = isnan(a)
inf_mask = isinf(a)

# Math
ab = abs(a)
sq2 = sqrt(a)
ex = exp(a)
lg = log(a)
cl = clip(a, 0.0, 1.0)
w = where(nan_mask, a, a)
