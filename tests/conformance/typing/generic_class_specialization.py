from typing import TypeVar, Generic, assert_type

T = TypeVar('T')
U = TypeVar('U')

class Pair(Generic[T, U]):
    first: T
    second: U
    def __init__(self, first: T, second: U) -> None:
        self.first = first
        self.second = second
    def get_first(self) -> T:
        return self.first
    def get_second(self) -> U:
        return self.second

# Constructor inference
p = Pair(42, "hello")
assert_type(p.get_first(), int)
assert_type(p.get_second(), str)

# Explicit annotation
p2: Pair[float, bool] = Pair(3.14, True)
assert_type(p2.get_first(), float)
assert_type(p2.get_second(), bool)

# Wrong type through specialization
r: str = p.get_first()  # E[T001]
