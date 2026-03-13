from typing import overload, assert_type

@overload
def process(x: int) -> str: ...
@overload
def process(x: str) -> int: ...
def process(x):
    if isinstance(x, int):
        return str(x)
    return len(x)

a = process(42)
assert_type(a, str)

b = process("hello")
assert_type(b, int)
