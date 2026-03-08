# Basic class conformance

class Point:
    x: int
    y: int

    def __init__(self, x: int, y: int):
        self.x = x
        self.y = y

# Correct usage — no errors
p = Point(1, 2)

# Wrong argument types
bad1 = Point("a", "b")   # E

# Wrong argument count
bad2 = Point(1)           # E
bad3 = Point(1, 2, 3)    # E
