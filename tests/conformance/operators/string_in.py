from typing import assert_type

# in operator returns bool
r1 = "hello" in ["hello", "world"]
assert_type(r1, bool)

r2 = 42 in [1, 2, 3]
assert_type(r2, bool)

# not in returns bool
r3 = "x" not in ["a", "b"]
assert_type(r3, bool)

# Wrong type from in
bad: str = 1 in [1, 2]  # E
