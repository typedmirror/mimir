from typing import assert_type

# Multiple elif branches all must match return type
def sign(x: int) -> str:
    if x > 0:
        return "positive"
    elif x < 0:
        return "negative"
    else:
        return "zero"

r = sign(42)
assert_type(r, str)

# Wrong return in one elif branch
def bad_sign(x: int) -> str:
    if x > 0:
        return "positive"
    elif x < 0:
        return -1  # E[T003]
    else:
        return "zero"
