from typing import assert_type

# Set literal inference
s1: set[int] = {1, 2, 3}
assert_type(s1, set[int])

s2 = {1, 2, 3}
assert_type(s2, set[int])

# Set operations
s3 = s1 | {4, 5}
assert_type(s3, set[int])

# Frozenset annotation
fs: frozenset[str] = frozenset(["a", "b"])
assert_type(fs, frozenset[str])

# Wrong element type in set annotation
bad: set[int] = {"a", "b"}  # E[T001]
