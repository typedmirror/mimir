from typing import assert_type

class Counter:
    def __init__(self, n: int) -> None:
        self.n = n

    def value(self) -> int:
        return self.n

    def name(self) -> str:
        return "counter"

c = Counter(0)

# Correct
assert_type(c.value(), int)
assert_type(c.name(), str)

# Errors
bad1: str = c.value()  # E
bad2: int = c.name()  # E
bad3 = c.value(42)  # E
