class Point:
    def __init__(self, x: int, y: int) -> None:
        self.x = x
        self.y = y

# Correct
p = Point(1, 2)

# Errors
bad1 = Point()  # E
bad2 = Point(1)  # E
bad3 = Point(1, 2, 3)  # E
bad4 = Point("a", "b")  # E
