# @property: method accessed as attribute, returns the return type

class Circle:
    def __init__(self, radius: float) -> None:
        self.radius = radius

    @property
    def area(self) -> float:
        return 3.14 * self.radius * self.radius

c = Circle(5.0)

# Property access returns float, not Callable
x: float = c.area

# Wrong type for property value
y: str = c.area  # E[T001]: Incompatible types
