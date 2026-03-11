from typing import Protocol

class Drawable(Protocol):
    def draw(self) -> None: ...

class Circle:
    def draw(self) -> None:
        pass

class Square:
    def draw(self) -> None:
        pass

class Empty:
    pass

def render(shape: Drawable) -> None:
    shape.draw()

# These should pass — structural match
render(Circle())
render(Square())

# This should fail — no draw method
render(Empty())  # E
