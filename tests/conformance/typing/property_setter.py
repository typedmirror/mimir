# @property.setter support — setter doesn't overwrite getter type

class Circle:
    def __init__(self, r: float) -> None:
        self._radius = r

    @property
    def radius(self) -> float:
        return self._radius

    @radius.setter
    def radius(self, value: float) -> None:
        self._radius = value

c = Circle(5.0)
x: str = c.radius  # E[T001]: Incompatible types
