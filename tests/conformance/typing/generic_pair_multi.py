from typing import assert_type, TypeVar, Generic

T = TypeVar('T')
U = TypeVar('U')

class Pair(Generic[T, U]):
    def __init__(self, first: T, second: U) -> None:
        self.first = first
        self.second = second

# Constructor infers both TypeVars
p = Pair(42, "hello")
assert_type(p.first, int)
assert_type(p.second, str)

# Different instantiation
p2 = Pair("x", 3.14)
assert_type(p2.first, str)
assert_type(p2.second, float)
