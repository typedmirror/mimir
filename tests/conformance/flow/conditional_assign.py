from typing import assert_type

# Typed variable reassigned consistently across branches
x: int = 0
if True:
    x = 10
else:
    x = 20
assert_type(x, int)

# Wrong type in one branch
y: str = "hello"
if True:
    y = 42  # E[T001]
else:
    y = "world"
