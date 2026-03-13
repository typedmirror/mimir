from typing import assert_type

# Type constructor return types
r1 = str(42)
assert_type(r1, str)

r2 = int("42")
assert_type(r2, int)

r3 = float(42)
assert_type(r3, float)

r4 = bool(1)
assert_type(r4, bool)

# abs returns int for int input
r5 = abs(-5)
assert_type(r5, int)

# Type constructors as wrong assignment targets
bad1: int = str(42)  # E
bad2: str = int("3")  # E
