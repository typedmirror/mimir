from typing import assert_type, TypeVar, Generic

T = TypeVar('T')

class Box(Generic[T]):
    def __init__(self, value: T) -> None:
        self.value = value

# Correct inference
b1 = Box(42)
assert_type(b1.value, int)

b2 = Box("hello")
assert_type(b2.value, str)

# Annotation mismatch: Box[int] but constructed with str
bad: Box[int] = Box("wrong")  # E[T001]
