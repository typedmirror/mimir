from typing import assert_type, TypeVar, Generic

T = TypeVar('T')

class Container(Generic[T]):
    def __init__(self, val: T) -> None:
        self.val = val

    def get(self) -> T:
        return self.val

# Method return type specializes with constructor arg
c = Container(42)
r = c.get()
assert_type(r, int)

s = Container("hello")
r2 = s.get()
assert_type(r2, str)
