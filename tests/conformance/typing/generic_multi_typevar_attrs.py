from typing import assert_type, TypeVar, Generic

T = TypeVar('T')
U = TypeVar('U')

class Pair(Generic[T, U]):
    def __init__(self, first: T, second: U) -> None:
        self.first = first
        self.second = second

# Constructor infers T=int, U=str
p = Pair(1, "hello")
assert_type(p.first, int)
assert_type(p.second, str)

# Different specialization
p2 = Pair("x", 3.14)
assert_type(p2.first, str)
assert_type(p2.second, float)

# Annotation-based specialization
p3: Pair[bool, int] = Pair(True, 42)
assert_type(p3.first, bool)
assert_type(p3.second, int)
