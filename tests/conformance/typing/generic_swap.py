from typing import assert_type, TypeVar

T = TypeVar('T')
U = TypeVar('U')

# Multi-TypeVar function
def swap(a: T, b: U) -> U:
    return b

# Return type follows second TypeVar
r1 = swap(42, "hello")
assert_type(r1, str)

r2 = swap("hello", 42)
assert_type(r2, int)

# Wrong type from swap result
bad: int = swap(42, "hello")  # E[T001]
