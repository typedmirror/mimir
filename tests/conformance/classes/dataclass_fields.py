from dataclasses import dataclass
from typing import assert_type

@dataclass
class Point:
    x: float
    y: float

# Correct construction
p = Point(1.0, 2.0)
assert_type(p.x, float)
assert_type(p.y, float)

# Wrong field type
bad = Point("hello", 2.0)  # E

# Wrong field count
bad2 = Point(1.0)  # E
