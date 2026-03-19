# Tests for functional NamedTuple isinstance support
# Functional syntax should register in class_types

from typing import NamedTuple

Point = NamedTuple('Point', x=int, y=int)

def check_point(obj) -> str:
    if isinstance(obj, Point):
        return "point"
    return "other"

p = Point(1, 2)
x: str = p.x  # E
