from typing import assert_type, TypeVar

T = TypeVar('T')
U = TypeVar('U')

def swap(a: T, b: U) -> tuple[U, T]:
    return (b, a)

# int, str -> tuple[str, int]
r1 = swap(1, "hello")
assert_type(r1, tuple[str, int])

# bool, float -> tuple[float, bool]
r2 = swap(True, 3.14)
assert_type(r2, tuple[float, bool])
