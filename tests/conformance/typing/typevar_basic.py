# TypeVar basic: identity function with type preservation
from typing import TypeVar

T = TypeVar('T')

def identity(x: T) -> T:
    return x

a: int = identity(42)
b: str = identity("hello")
bad1: str = identity(42)    # E[T001]
bad2: int = identity("hi")  # E[T001]
