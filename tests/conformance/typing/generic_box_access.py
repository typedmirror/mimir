from typing import assert_type, TypeVar, Generic

T = TypeVar('T')

class Box(Generic[T]):
    def __init__(self, val: T) -> None:
        self.val = val

# Constructor infers type from arg
b = Box(42)
assert_type(b.val, int)

s = Box("hello")
assert_type(s.val, str)
