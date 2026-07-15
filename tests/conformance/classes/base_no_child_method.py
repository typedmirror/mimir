from typing import assert_type

class Base:
    def method(self) -> str:
        return "base"

class Child(Base):
    def method(self) -> str:
        return "child"

    def extra(self) -> int:
        return 42

c = Child()
assert_type(c.method(), str)
assert_type(c.extra(), int)

# Base instance doesn't have child's extra method
b = Base()
b.extra()  # E[T007]
