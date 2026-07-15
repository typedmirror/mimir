from typing import assert_type

class Shape:
    def area(self) -> float:
        return 0.0

class Circle(Shape):
    def radius(self) -> float:
        return 1.0

class Square(Shape):
    def side(self) -> float:
        return 1.0

# Subclass assignable to parent
s1: Shape = Circle()
s2: Shape = Square()

# Sibling classes not assignable to each other
bad1: Circle = Square()  # E[T001]
bad2: Square = Circle()  # E[T001]
