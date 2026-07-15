# ParamSpec: decorator type preservation

from typing import ParamSpec, Callable, TypeVar

P = ParamSpec('P')
R = TypeVar('R')

def decorator(func: Callable[P, R]) -> Callable[P, R]:
    return func

@decorator
def add(x: int, y: int) -> int:
    return x + y

# Decorated function retains its original signature
result: str = add(1, 2)  # E[T001]: Incompatible types
