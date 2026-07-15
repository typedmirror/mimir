from typing import assert_type

# Comparison operators all return bool
r1 = 1 < 2
assert_type(r1, bool)

r2 = "a" == "b"
assert_type(r2, bool)

r3 = 3 >= 2
assert_type(r3, bool)

r4 = 1 != 2
assert_type(r4, bool)

# Wrong type from comparison
bad: str = 1 < 2  # E[T001]
