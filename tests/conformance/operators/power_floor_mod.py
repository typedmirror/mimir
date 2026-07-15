from typing import assert_type

# Power operator returns int for int operands
r1 = 2 ** 10
assert_type(r1, int)

# Floor division returns int
r2 = 10 // 3
assert_type(r2, int)

# Modulo returns int
r3 = 10 % 3
assert_type(r3, int)

# String concatenation
r4 = "hello" + " " + "world"
assert_type(r4, str)

# String repetition
r5 = "ha" * 3
assert_type(r5, str)

# Wrong: power result to str
bad: str = 2 ** 10  # E[T001]
