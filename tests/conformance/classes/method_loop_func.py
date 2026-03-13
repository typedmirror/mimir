from typing import assert_type

class Circle:
    radius: float
    def __init__(self, radius: float):
        self.radius = radius
    def area(self) -> float:
        return 3.14159 * self.radius * self.radius

# Method call in loop within function
def total_area(circles: list[Circle]) -> float:
    total = 0.0
    for c in circles:
        total += c.area()
    return total
