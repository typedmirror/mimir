from typing import assert_type

class Vec2:
    x: float
    y: float
    def __init__(self, x: float, y: float):
        self.x = x
        self.y = y

    # Method constructing new instance of own class
    def add(self, other: "Vec2") -> "Vec2":
        return Vec2(self.x + other.x, self.y + other.y)
