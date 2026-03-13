from typing import assert_type, Union

class Shape:
    def __init__(self, name: str) -> None:
        self.name = name

class Circle(Shape):
    def __init__(self, radius: float) -> None:
        self.radius = radius

class Square(Shape):
    def __init__(self, side: float) -> None:
        self.side = side

# isinstance narrows user-defined class unions
def classify(s: Union[Circle, Square]) -> str:
    if isinstance(s, Circle):
        assert_type(s, Circle)
        return "circle"
    else:
        assert_type(s, Square)
        return "square"
