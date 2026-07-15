from typing import assert_type

class Base:
    def method(self) -> str:
        return "base"

class Middle(Base):
    def middle_method(self) -> int:
        return 42

class Child(Middle):
    pass

c = Child()
# Grandchild can access grandparent method
r1 = c.method()
assert_type(r1, str)

# And parent method
r2 = c.middle_method()
assert_type(r2, int)

# Subtype assignability through chain
b: Base = Child()
m: Middle = Child()

# Reverse is not OK
bad: Child = Base()  # E[T001]
