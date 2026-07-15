# ParamSpec decorator preservation — type preserved through @decorator

from typing import ParamSpec, TypeVar, Callable

P = ParamSpec('P')
R = TypeVar('R')

def decorator(func: Callable[P, R]) -> Callable[P, R]:
    return func

@decorator
def add(a: int, b: int) -> int:
    return a + b

result: str = add(1, 2)  # E[T001]: Incompatible types
