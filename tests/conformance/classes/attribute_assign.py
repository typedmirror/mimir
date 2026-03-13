from typing import assert_type

class Typed:
    x: int
    name: str
    def __init__(self, x: int, name: str) -> None:
        self.x = x
        self.name = name

t = Typed(1, "hello")
assert_type(t.x, int)
assert_type(t.name, str)

# Attribute access return types
r: int = t.x
s: str = t.name

# Wrong type assignment to typed attribute
bad1: str = t.x  # E
bad2: int = t.name  # E
