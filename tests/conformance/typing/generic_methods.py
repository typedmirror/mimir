# Generic class with mixed params
from typing import TypeVar, Generic

T = TypeVar('T')

class Pair(Generic[T]):
    def __init__(self, first: T, second: T) -> None:
        self.first = first
        self.second = second

    def get_first(self) -> T:
        return self.first

p: Pair[int] = Pair(1, 2)
a: int = p.get_first()
b: str = p.get_first()    # E

bad1: Pair[int] = Pair("a", "b")  # E
bad2: Pair[str] = Pair(1, 2)      # E
