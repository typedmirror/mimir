from typing import assert_type, Generic, TypeVar

T = TypeVar('T')
U = TypeVar('U')

class Pair(Generic[T, U]):
    first: T
    second: U
    def __init__(self, first: T, second: U):
        self.first = first
        self.second = second

# Generic class with two TypeVars — constructor + attr inference
def make_pair():
    p = Pair(1, "hello")
    assert_type(p, Pair[int, str])
    assert_type(p.first, int)
    assert_type(p.second, str)
