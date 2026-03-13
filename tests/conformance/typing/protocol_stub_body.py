from typing import Protocol

# Protocol methods with ... body should not trigger F002
class Drawable(Protocol):
    def draw(self) -> str: ...

class Renderable(Protocol):
    def render(self) -> int: ...

# Regular function with pass stub should also not trigger F002
def abstract_method() -> int:
    pass
