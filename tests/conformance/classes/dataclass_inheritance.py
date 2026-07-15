from typing import assert_type
from dataclasses import dataclass

@dataclass
class Base:
    name: str

@dataclass
class Child(Base):
    age: int

# Parent + child fields accepted
c = Child(name="Alice", age=30)
assert_type(c, Child)

# Wrong type for inherited field
bad = Child(name=42, age=30)  # E[T002]
