from typing import assert_type

# Reassignment with incompatible type
x: int = 42
x = "hello"  # E[T001]

y: str = "hello"
y = 42  # E[T001]

# Valid reassignment preserves declared type
z: str = "first"
z = "second"
assert_type(z, str)

w: int = 1
w = 2
assert_type(w, int)
