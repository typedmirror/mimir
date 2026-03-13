from typing import assert_type

class Base:
    def value(self) -> int:
        return 0

    def name(self) -> str:
        return "base"

class Child(Base):
    def value(self) -> int:
        return 42

    def name(self) -> str:
        return "child"

c = Child()
assert_type(c.value(), int)
assert_type(c.name(), str)

b = Base()
assert_type(b.value(), int)
assert_type(b.name(), str)
