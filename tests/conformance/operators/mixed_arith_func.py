from typing import assert_type

# Mixed int/float arithmetic in function scope
def compute(x: int, y: float) -> float:
    a = x + y
    assert_type(a, float)
    b = x * y
    assert_type(b, float)
    c = y / x
    assert_type(c, float)
    return a + b + c
