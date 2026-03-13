from typing import assert_type, Generic, TypeVar

T = TypeVar('T')

class Box(Generic[T]):
    value: T
    def __init__(self, value: T):
        self.value = value

# Generic class constructor in function body
def wrap_value():
    b = Box(42)
    assert_type(b, Box[int])
    return b
