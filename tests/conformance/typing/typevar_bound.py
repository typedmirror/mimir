# TypeVar with upper bound
from typing import TypeVar

T = TypeVar('T', bound=int)

def process(x: T) -> T:
    return x

a: int = process(42)
b: int = process(True)
bad = process("hi")  # E[T008]
