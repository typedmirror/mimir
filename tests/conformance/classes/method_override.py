from typing import assert_type

class Base:
    def greet(self) -> str:
        return "hello"

class Child(Base):
    def greet(self) -> str:
        return "hi"

    def extra(self) -> int:
        return 42

c = Child()
r1 = c.greet()
assert_type(r1, str)

r2 = c.extra()
assert_type(r2, int)

# Access via base type
b: Base = Child()
r3 = b.greet()
assert_type(r3, str)

# Base doesn't have extra
b.extra()  # E
