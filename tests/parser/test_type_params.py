"""Test PEP 695 type parameter syntax (Python 3.12+)."""

type Point = tuple[int, int]
type Vector[T] = list[T]

def first[T](items: list[T]) -> T:
    return items[0]

class Stack[T]:
    def __init__(self) -> None:
        self._items: list[T] = []

    def push(self, item: T) -> None:
        self._items.append(item)
