from typing import TypeVar, Generic, assert_type

T = TypeVar('T')

# M04: TypeVar inference from keyword arguments
def make_pair(first: T, second: T) -> list:
    return [first, second]

# Keyword-only TypeVar inference
r1 = make_pair(first=1, second=2)
assert_type(r1, list)

# Mixed positional + keyword TypeVar inference
r2 = make_pair(1, second=2)
assert_type(r2, list)

# Keyword arg type mismatch with TypeVar (positional binds T=int, keyword gives str)
make_pair(1, second="hello")  # E[T002]

# Generic class constructor with keyword args
class Box(Generic[T]):
    def __init__(self, value: T) -> None:
        self.value = value

b = Box(value=42)
assert_type(b, Box[int])
