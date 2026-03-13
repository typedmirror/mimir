from typing import assert_type

class Base:
    def value(self) -> int:
        return 0

class Child(Base):
    def value(self) -> int:
        return 42

# Inheritance method call in function scope
def get_value() -> int:
    c = Child()
    return c.value()
