from typing import assert_type

class Point:
    def __init__(self, x: int, y: int) -> None:
        self.x = x
        self.y = y

p = Point(1, 2)
assert_type(p.x, int)
assert_type(p.y, int)

# Attribute access returns typed value — wrong assignment
bad: str = p.x  # E
