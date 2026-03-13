from typing import assert_type

# bool -> int -> float promotion chain
b: bool = True
i: int = b       # OK: bool <: int
f: float = i     # OK: int <: float

assert_type(b, bool)
assert_type(i, int)
assert_type(f, float)

# Reverse is NOT OK
bad1: bool = 42    # E
bad2: int = 3.14   # E
bad3: bool = 1.0   # E
