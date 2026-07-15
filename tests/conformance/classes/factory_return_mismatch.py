from typing import assert_type

class Circle:
    radius: float
    def __init__(self, radius: float):
        self.radius = radius

class Square:
    side: float
    def __init__(self, side: float):
        self.side = side

def create_circle(r: float) -> Circle:
    return Circle(r)

def create_square(s: float) -> Square:
    return Square(s)

# Wrong factory return — Square is not Circle
def bad_factory() -> Circle:
    return Square(5.0)  # E[T003]
