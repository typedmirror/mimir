from typing import assert_type, TypeVar

T = TypeVar('T')

def identity(x: T) -> T:
    return x

# Generic preserves concrete type through each call
r1 = identity(42)
assert_type(r1, int)

r2 = identity("hello")
assert_type(r2, str)

r3 = identity([1, 2, 3])
assert_type(r3, list)

r4 = identity(True)
assert_type(r4, bool)
