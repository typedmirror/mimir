from typing import TypeVar, Generic

T = TypeVar('T')
U = TypeVar('U')

class Pair(Generic[T, U]):
    def __init__(self, first: T, second: U) -> None:
        self.first = first
        self.second = second

    def get_first(self) -> T:
        return self.first

    def get_second(self) -> U:
        return self.second

p = Pair(1, "hello")

# Correct
good1: int = p.get_first()
good2: str = p.get_second()

# Errors
bad1: str = p.get_first()  # E[T001]
bad2: int = p.get_second()  # E[T001]
bad3: Pair[str, int] = Pair(1, "hello")  # E[T001]
