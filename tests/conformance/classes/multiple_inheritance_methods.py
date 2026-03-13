from typing import assert_type

class Printable:
    def to_string(self) -> str:
        return ""

class Saveable:
    def save(self) -> bool:
        return True

class Document(Printable, Saveable):
    def __init__(self, title: str) -> None:
        self.title = title

d = Document("Test")
assert_type(d, Document)
assert_type(d.title, str)

# Inherited methods from both parents
assert_type(d.to_string(), str)
assert_type(d.save(), bool)

# Nonexistent method
d.delete()  # E
