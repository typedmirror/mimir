# TypeVar with value constraints
from typing import TypeVar

T = TypeVar('T', int, str)

def convert(x: T) -> T:
    return x

a: int = convert(42)
b: str = convert("hi")
bad = convert(3.14)  # E
