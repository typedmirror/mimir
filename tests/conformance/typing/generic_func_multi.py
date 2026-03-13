from typing import TypeVar, assert_type

T = TypeVar('T')
U = TypeVar('U')

def swap(a: T, b: U) -> U:
    return b

r1 = swap(42, "hello")
assert_type(r1, str)

r2 = swap("x", 3.14)
assert_type(r2, float)

# Return type matches second param type
bad: int = swap(42, "hello")  # E
