from typing import assert_type

class Point:
    x: float
    y: float
    def __init__(self, x: float, y: float):
        self.x = x
        self.y = y

# Module level
m = Point(1.0, 2.0)
assert_type(m, Point)

# Function body — class constructor resolves correctly
def make_origin() -> Point:
    return Point(0.0, 0.0)

r = make_origin()
assert_type(r, Point)

# Constructor arg count errors in function
def bad_constructor():
    p = Point(1.0)  # E
