from typing import assert_type, Tuple

# Tuple return type
def divmod_custom(a: int, b: int) -> Tuple[int, int]:
    return (a // b, a % b)

r = divmod_custom(10, 3)
assert_type(r, Tuple[int, int])

# Wrong element in tuple return
def bad_divmod(a: int, b: int) -> Tuple[int, int]:
    return (a, "oops")  # E
