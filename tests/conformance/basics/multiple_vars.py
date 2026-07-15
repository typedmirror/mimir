from typing import assert_type

# Multiple typed variables
a: int = 1
b: str = "hello"
c: float = 3.14
d: bool = True

assert_type(a, int)
assert_type(b, str)
assert_type(c, float)
assert_type(d, bool)

# Cross-assignment error
bad1: str = a  # E[T001]
bad2: int = b  # E[T001]
