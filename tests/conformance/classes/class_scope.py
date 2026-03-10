class Rect:
    def __init__(self, w: int, h: int) -> None:
        self.w = w
        self.h = h

    def area(self) -> int:
        return self.w * self.h

    def label(self) -> str:
        return "rect"

r = Rect(3, 4)

# Errors
bad1: str = r.area()  # E
bad2: int = r.label()  # E
bad3 = Rect("a", "b")  # E
