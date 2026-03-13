from typing import assert_type

class Color:
    r: int
    g: int
    b: int
    def __init__(self, r: int, g: int, b: int):
        self.r = r
        self.g = g
        self.b = b

class Pixel:
    x: int
    y: int
    color: Color
    def __init__(self, x: int, y: int, color: Color):
        self.x = x
        self.y = y
        self.color = color

# Compose classes inside function
def make_red_pixel(x: int, y: int) -> Pixel:
    c = Color(255, 0, 0)
    return Pixel(x, y, c)

r = make_red_pixel(0, 0)
assert_type(r, Pixel)
