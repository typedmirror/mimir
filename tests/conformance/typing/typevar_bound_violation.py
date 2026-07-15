from typing import TypeVar, assert_type

T = TypeVar('T', bound=int)

def double(x: T) -> T:
    return x

# OK: int satisfies bound=int
r1 = double(42)
assert_type(r1, int)

# OK: bool satisfies bound=int (bool <: int)
r2 = double(True)
assert_type(r2, bool)

# Bad: str does not satisfy bound=int
r3 = double("hello")  # E[T008]
