# Generic class with TypeVar
from typing import TypeVar, Generic

T = TypeVar('T')

class Box(Generic[T]):
    def __init__(self, value: T) -> None:
        self.value = value
    def get(self) -> T:
        return self.value

box: Box[int] = Box(42)
x: int = box.get()
y: str = box.get()    # E
bad: Box[str] = Box(42)  # E
z: int = Box("hi").get()  # E
