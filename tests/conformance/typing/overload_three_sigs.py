from typing import overload, assert_type

@overload
def convert(x: int) -> str: ...
@overload
def convert(x: str) -> int: ...
@overload
def convert(x: float) -> bool: ...
def convert(x):
    if isinstance(x, int):
        return str(x)
    elif isinstance(x, str):
        return int(x)
    return x > 0

a = convert(42)
assert_type(a, str)

b = convert("hello")
assert_type(b, int)

c = convert(3.14)
assert_type(c, bool)
