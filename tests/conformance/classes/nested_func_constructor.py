from typing import assert_type

class Wrapper:
    val: int
    def __init__(self, val: int):
        self.val = val

# Nested function can construct module-level class
def outer():
    def inner() -> Wrapper:
        return Wrapper(10)
    r = inner()
    assert_type(r, Wrapper)
