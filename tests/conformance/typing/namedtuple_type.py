# NamedTuple: typed tuple class with named fields

from typing import NamedTuple

Point = NamedTuple('Point', x=int, y=int)

p = Point(x=1, y=2)

# Field access returns the declared type
a: int = p.x
b: int = p.y

# Wrong type for field
c: str = p.x  # E: Incompatible types
