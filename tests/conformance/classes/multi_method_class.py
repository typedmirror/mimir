from typing import assert_type

class Counter:
    def __init__(self, count: int) -> None:
        self.count = count

    def increment(self) -> int:
        return self.count + 1

    def get_count(self) -> int:
        return self.count

c = Counter(0)
assert_type(c.count, int)
assert_type(c.increment(), int)
assert_type(c.get_count(), int)

# Method result has wrong type assigned
bad: str = c.get_count()  # E
