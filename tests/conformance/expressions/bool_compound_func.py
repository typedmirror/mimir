from typing import assert_type

# Complex boolean expressions in function scope
def complex_bool(x: int, y: int, name: str) -> bool:
    a = x > 0 and y > 0
    assert_type(a, bool)
    b = x == y or name == "test"
    assert_type(b, bool)
    c = not (x < 0)
    assert_type(c, bool)
    return a and b and c
