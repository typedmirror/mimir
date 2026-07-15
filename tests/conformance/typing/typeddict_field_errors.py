from typing import assert_type, TypedDict

class Point(TypedDict):
    x: int
    y: int

# Correct construction
p = Point(x=1, y=2)
assert_type(p, Point)

# Missing required field
Point(x=1)  # E[T004]

# Wrong field type
Point(x="wrong", y=2)  # E[T002]
