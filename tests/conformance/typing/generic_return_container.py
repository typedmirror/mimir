from typing import TypeVar, List, assert_type

T = TypeVar('T')

def wrap(x: T) -> List[T]:
    return [x]

# Generic return wrapping
r1 = wrap(42)
assert_type(r1, List[int])

r2 = wrap("hi")
assert_type(r2, List[str])
