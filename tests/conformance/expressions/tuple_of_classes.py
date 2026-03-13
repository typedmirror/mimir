from typing import assert_type

class X:
    v: int
    def __init__(self, v: int):
        self.v = v

class Y:
    v: str
    def __init__(self, v: str):
        self.v = v

# Tuple of different class instances in function
def make_pair() -> tuple[X, Y]:
    return (X(1), Y("a"))
