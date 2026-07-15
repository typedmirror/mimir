from typing import assert_type

class Person:
    def __init__(self, name: str, age: int) -> None:
        self.name = name
        self.age = age

p = Person("Alice", 30)
assert_type(p.name, str)
assert_type(p.age, int)

# Nonexistent attributes
p.email  # E[T007]
p.phone  # E[T007]
