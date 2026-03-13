from typing import assert_type

class Builder:
    def __init__(self, name: str) -> None:
        self.name = name

    def get_name(self) -> str:
        return self.name

    def name_length(self) -> int:
        return len(self.name)

b = Builder("test")
assert_type(b.get_name(), str)
assert_type(b.name_length(), int)

# Wrong type from method
bad: int = b.get_name()  # E
