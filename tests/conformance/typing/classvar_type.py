# ClassVar: class-level attribute annotation

from typing import ClassVar

class Counter:
    count: ClassVar[int] = 0
    name: str

    def __init__(self, name: str) -> None:
        self.name = name

# ClassVar resolves to the inner type correctly
x: int = Counter.count
wrong: str = Counter.count  # E: Incompatible types
