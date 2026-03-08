# assert_type conformance

from typing import assert_type

# Basic type assertions — should pass
x: int = 1
assert_type(x, int)

y: str = "hello"
assert_type(y, str)

# Type mismatches — should error
assert_type(x, str)       # E
assert_type(y, int)       # E

# Any passes (no error)
from typing import Any
z: Any = 42
assert_type(z, Any)

# Class types
class Foo:
    pass

f = Foo()
assert_type(f, Foo)
assert_type(f, int)       # E
