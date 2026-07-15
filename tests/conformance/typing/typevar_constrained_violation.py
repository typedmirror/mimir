from typing import TypeVar, assert_type

T = TypeVar('T', int, str)

def identity(x: T) -> T:
    return x

# OK: int is a constraint choice
r1 = identity(42)
assert_type(r1, int)

# OK: str is a constraint choice
r2 = identity("hi")
assert_type(r2, str)

# Bad: float is not one of the constraints
r3 = identity(3.14)  # E[T008]
