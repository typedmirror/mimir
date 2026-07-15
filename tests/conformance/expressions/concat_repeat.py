from typing import assert_type

# String concatenation returns str
r1 = "hello" + " world"
assert_type(r1, str)

# String repetition returns str
r2 = "abc" * 3
assert_type(r2, str)

# List concatenation returns list
r3 = [1, 2] + [3, 4]
assert_type(r3, list)

# Wrong type from concatenation
bad: int = "hello" + " world"  # E[T001]
