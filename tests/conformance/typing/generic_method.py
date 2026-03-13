from typing import TypeVar, Generic, assert_type

T = TypeVar('T')

class Box(Generic[T]):
    value: T
    def __init__(self, value: T) -> None:
        self.value = value
    def get(self) -> T:
        return self.value

# Constructor + method return type specialization
b = Box(42)
assert_type(b.get(), int)

b2 = Box("hello")
assert_type(b2.get(), str)

# Explicit specialization
b3: Box[float] = Box(3.14)
assert_type(b3.get(), float)
