from typing import assert_type
from dataclasses import dataclass

@dataclass
class Base:
    x: int

@dataclass
class Middle(Base):
    y: str

@dataclass
class Child(Middle):
    z: float

# 3-level chain: all fields accessible
c = Child(x=1, y="hi", z=3.14)
assert_type(c, Child)
assert_type(c.x, int)
assert_type(c.y, str)
assert_type(c.z, float)

# Field override: child redefines parent field type
@dataclass
class Override(Base):
    x: str

o = Override(x="hello")
assert_type(o.x, str)

# Missing field in 3-level chain
Child(x=1, y="hi")  # E[T004]
