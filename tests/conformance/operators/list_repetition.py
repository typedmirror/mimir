from typing import assert_type

# List repetition: list[T] * int → list[T]
xs = [0] * 5
assert_type(xs, list[int])

ys = 3 * ["hello"]
assert_type(ys, list[str])

# In function scope
def make_zeros(n: int) -> list[int]:
    return [0] * n
