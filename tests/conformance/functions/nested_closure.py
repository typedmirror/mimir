from typing import assert_type

# Nested function with return type annotation
def outer() -> str:
    x: int = 10

    def inner() -> int:
        return x

    r = inner()
    assert_type(r, int)
    return "done"

# Nested function with different return type
def outer2() -> str:
    def inner2() -> int:
        return 42

    r = inner2()
    assert_type(r, int)
    return "ok"
