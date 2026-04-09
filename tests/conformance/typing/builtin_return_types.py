"""Builtin functions return correct types from container args."""
from typing import assert_type, List

nums: List[float] = [1.0, 2.0, 3.0]
strings: List[str] = ["a", "b", "c"]

# min/max infer element type from List[T]
mn = min(nums)
assert_type(mn, float)
mx = max(nums)
assert_type(mx, float)

# Arithmetic on min/max results should work
rng = mx - mn
assert_type(rng, float)

# sorted returns List[T]
s = sorted(nums)
assert_type(s, list)

# sum returns int for int lists, float for float lists
total = sum(nums)
assert_type(total, float)
