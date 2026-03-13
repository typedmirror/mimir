from dataclasses import dataclass
from typing import assert_type

@dataclass
class Point:
    x: int
    y: int

p1 = Point(1, 2)
p2 = Point(1, 2)

# __eq__ returns bool
r1 = p1 == p2
assert_type(r1, bool)

# __repr__ returns str
r2 = repr(p1)
assert_type(r2, str)
