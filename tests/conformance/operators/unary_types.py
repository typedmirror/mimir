from typing import assert_type

# Unary minus on int
r1 = -42
assert_type(r1, int)

# Unary minus on float
r2 = -3.14
assert_type(r2, float)

# Unary not returns bool
r3 = not True
assert_type(r3, bool)

r4 = not 0
assert_type(r4, bool)

# Bitwise invert on int
r5 = ~42
assert_type(r5, int)

# Unary not result assigned to wrong type
bad: str = not True  # E[T001]
