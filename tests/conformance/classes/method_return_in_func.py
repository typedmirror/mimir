from typing import assert_type

class Counter:
    count: int
    def __init__(self):
        self.count = 0
    def increment(self) -> int:
        self.count += 1
        return self.count

# Method call return type in function scope
def use_counter() -> int:
    c = Counter()
    return c.increment()
