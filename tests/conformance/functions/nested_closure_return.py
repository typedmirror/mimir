from typing import assert_type

def outer() -> int:
    def inner() -> int:
        return "wrong"  # E[T003]
    return inner()

def outer2() -> str:
    def inner2() -> str:
        return "correct"
    return inner2()
