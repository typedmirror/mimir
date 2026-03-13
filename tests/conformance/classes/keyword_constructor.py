from typing import assert_type

class Rect:
    width: int
    height: int
    def __init__(self, width: int, height: int):
        self.width = width
        self.height = height

# Keyword arguments to class constructor in function
def make_rect():
    r = Rect(width=10, height=20)
    assert_type(r, Rect)
