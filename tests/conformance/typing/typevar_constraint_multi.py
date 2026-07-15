from typing import TypeVar, assert_type

T = TypeVar('T', int, str)

def identity(x: T) -> T:
    return x

# Valid calls
r1 = identity(42)
assert_type(r1, int)

r2 = identity("hello")
assert_type(r2, str)

# Invalid — bool is subtype of int so OK
r3 = identity(True)

# Invalid — float not in constraints
identity(3.14)  # E[T008]
