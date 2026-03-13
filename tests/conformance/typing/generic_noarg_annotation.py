from typing import assert_type, Generic, TypeVar

T = TypeVar('T')

class Stack(Generic[T]):
    items: list[T]
    def __init__(self):
        self.items = []

# No-arg generic constructor with annotation — type inferred from annotation
s: Stack[int] = Stack()
assert_type(s, Stack[int])
