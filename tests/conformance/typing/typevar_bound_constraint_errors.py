from typing import TypeVar

T = TypeVar('T', bound=int)

def add_one(x: T) -> T:
    return x + 1

# Bound violation: str not assignable to int bound
add_one("hello")  # E[T008]

# Constrained TypeVar
S = TypeVar('S', int, str)

def process(x: S) -> S:
    return x

# Constraint violation: float not in (int, str)
process(3.14)  # E[T008]
