from typing import assert_type

class Counter:
    def __init__(self):
        self.count = 0
        self.name = "counter"
        self.active = True

    def get_count(self) -> int:
        return self.count

    def get_name(self) -> str:
        return self.name

c = Counter()
assert_type(c.count, int)
assert_type(c.name, str)
assert_type(c.active, bool)

# Nonexistent attribute
bad = c.nonexistent  # E[T007]
