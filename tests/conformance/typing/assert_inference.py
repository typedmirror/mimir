from typing import assert_type

x: int = 42
y: str = "hello"
z: float = 3.14

# Correct
assert_type(x, int)
assert_type(y, str)
assert_type(z, float)

# Wrong — T006
assert_type(x, str)  # E[T006]
assert_type(y, int)  # E[T006]
assert_type(z, int)  # E[T006]
assert_type(x, bool)  # E[T006]
