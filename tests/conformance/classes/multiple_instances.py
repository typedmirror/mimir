from typing import assert_type

class Pair:
    def __init__(self, x: int, y: str) -> None:
        self.x = x
        self.y = y

# Multiple instances preserve types independently
a = Pair(1, "hello")
b = Pair(2, "world")
assert_type(a.x, int)
assert_type(a.y, str)
assert_type(b.x, int)
assert_type(b.y, str)

# Wrong argument type in construction
Pair("not_int", "hello")  # E[T002]
