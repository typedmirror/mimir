# Class type checking test — class definition, attribute access
# Expected: errors for type mismatches

class Point:
    def __init__(self, x: int, y: int):
        self.x = x
        self.y = y

p = Point(1, 2)
a: int = p.x       # ok
