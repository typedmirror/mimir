from typing import assert_type
from mimir.stats import median, mode, skew, kurtosis, percentile
from mimir.array import zeros

a = zeros((100,))

m = median(a)
assert_type(m, float)
mo = mode(a)
assert_type(mo, float)
sk = skew(a)
assert_type(sk, float)
k = kurtosis(a)
assert_type(k, float)
p = percentile(a, 95.0)
assert_type(p, float)
