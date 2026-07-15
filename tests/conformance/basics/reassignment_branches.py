from typing import assert_type

# Reassignment in sequence
x: int = 42
x = 10
assert_type(x, int)

# Bad reassignment after multiple good ones
y: str = "a"
y = "b"
y = "c"
y = 42  # E[T001]

# Annotated but assigned wrong later
z: float = 1.0
z = 2
z = "bad"  # E[T001]
