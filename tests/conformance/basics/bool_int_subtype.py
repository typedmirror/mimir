from typing import assert_type

# bool is a subtype of int
b: bool = True
i: int = b
assert_type(i, int)

# int is NOT a subtype of bool
bad: bool = 42  # E[T001]

# bool + int = int
r = True + 1
assert_type(r, int)

# bool operations
r2 = True and False
assert_type(r2, bool)
