from typing import assert_type

# Basic assert_type passes
x: int = 42
assert_type(x, int)

y: str = "hello"
assert_type(y, str)

# Bool is int subtype — but assert_type is exact
b: bool = True
assert_type(b, bool)

# Mismatch fails
assert_type(x, str)  # E
assert_type(y, int)  # E
