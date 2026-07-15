from dataclasses import dataclass
from typing import assert_type

@dataclass
class Point:
    x: int
    y: float

p = Point(x=1, y=2.0)
assert_type(p, Point)

# Wrong type for field
Point(x="bad", y=2.0)  # E[T002]

# Too few args
Point(x=1)  # E[T004]

@dataclass
class Config:
    name: str
    debug: bool = False

# Default field — 1 required, 1 optional
c = Config(name="test")
assert_type(c, Config)
