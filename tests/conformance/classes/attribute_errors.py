# Attribute access validation conformance

class Point:
    x: int
    y: int
    def __init__(self, x: int, y: int):
        self.x = x
        self.y = y
    def distance(self) -> float:
        return 0.0

p = Point(1, 2)

# Valid accesses — no errors
_ = p.x
_ = p.y
_ = p.distance()

# Invalid accesses — T007
_ = p.z           # E[T007]
_ = p.nonexistent # E[T007]

class Animal:
    name: str

class Dog(Animal):
    breed: str

d = Dog()

# Inherited attr is valid
_ = d.name

# Nonexistent attr on subclass
_ = d.color  # E[T007]
