from typing import assert_type

# All comparisons return bool
r1 = 1 < 2
assert_type(r1, bool)

r2 = 1 <= 2
assert_type(r2, bool)

r3 = 1 > 2
assert_type(r3, bool)

r4 = 1 >= 2
assert_type(r4, bool)

r5 = 1 == 2
assert_type(r5, bool)

r6 = 1 != 2
assert_type(r6, bool)

# Comparison result as wrong type
bad: str = 1 < 2  # E[T001]
