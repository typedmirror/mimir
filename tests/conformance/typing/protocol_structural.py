from typing import Protocol, assert_type

class Printable(Protocol):
    def to_string(self) -> str:
        return ""

class User:
    def __init__(self, name: str) -> None:
        self.name = name

    def to_string(self) -> str:
        return self.name

# Structural subtype — User has to_string method
p: Printable = User("Alice")

# Wrong: missing to_string method
class Empty:
    pass

bad: Printable = Empty()  # E[T001]
