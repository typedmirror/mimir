from typing import assert_type

def outer() -> int:
    def inner() -> int:
        return "wrong"  # E
    return inner()

def outer2() -> str:
    def inner2() -> str:
        return "correct"
    return inner2()
