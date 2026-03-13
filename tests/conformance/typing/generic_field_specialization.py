from typing import assert_type, Generic, TypeVar

T = TypeVar('T')

class Box(Generic[T]):
    def __init__(self, value: T):
        self.value = value

# Specialization preserves concrete type in field
b = Box(42)
assert_type(b.value, int)

s = Box("hello")
assert_type(s.value, str)
