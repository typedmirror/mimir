# Inheritance method resolution conformance

from typing import assert_type

class Base:
    x: int = 10
    def greet(self) -> str:
        return "hello"
    def shared(self) -> int:
        return 1

class Child(Base):
    def own_method(self) -> bool:
        return True
    def shared(self) -> int:
        return 2  # override

class GrandChild(Child):
    def gc_method(self) -> float:
        return 3.0

# Inherited method from direct base
c = Child(x=1)
assert_type(c.greet(), str)

# Own method
assert_type(c.own_method(), bool)

# Override: own version wins
assert_type(c.shared(), int)

# Inherited attribute from base
assert_type(c.x, int)

# Multi-level: GrandChild inherits from Child inherits from Base
gc = GrandChild(x=1)
assert_type(gc.greet(), str)       # from Base
assert_type(gc.own_method(), bool) # from Child
assert_type(gc.gc_method(), float) # own
assert_type(gc.shared(), int)      # from Child (override of Base)
assert_type(gc.x, int)             # from Base
