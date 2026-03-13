from typing import assert_type

class Base:
    def __init__(self, x: int) -> None:
        self.x = x

class Mid(Base):
    def __init__(self, x: int, y: str) -> None:
        self.x = x
        self.y = y

class Leaf(Mid):
    def __init__(self, x: int, y: str, z: float) -> None:
        self.x = x
        self.y = y
        self.z = z

leaf = Leaf(1, "hello", 3.14)
assert_type(leaf.x, int)
assert_type(leaf.y, str)
assert_type(leaf.z, float)

# Wrong number of args
Leaf(1, "hello")  # E
