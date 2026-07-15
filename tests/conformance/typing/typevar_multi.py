# TypeVar multi: multiple type variables in function signature
from typing import TypeVar

T = TypeVar('T')
U = TypeVar('U')

def first(x: T, y: U) -> T:
    return x

a: int = first(42, "hello")
b: str = first("hi", 99)
bad1: str = first(42, "x")   # E[T001]
bad2: int = first("hi", 99)  # E[T001]
