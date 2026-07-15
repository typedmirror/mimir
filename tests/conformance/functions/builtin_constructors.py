from typing import assert_type

# Type constructors return their respective types
r1 = bool(0)
assert_type(r1, bool)

r2 = int("42")
assert_type(r2, int)

r3 = float(42)
assert_type(r3, float)

r4 = str(42)
assert_type(r4, str)

# len() returns int
r5 = len([1, 2, 3])
assert_type(r5, int)

# abs() returns int
r6 = abs(-42)
assert_type(r6, int)

# Wrong type from constructor
bad: str = int("42")  # E[T001]
