from typing import assert_type, TypeVar

class Shape:
    area: float
    def __init__(self, area: float):
        self.area = area

S = TypeVar('S', bound=Shape)

# TypeVar bound to user class — attr access works
def double_area(s: S) -> float:
    return s.area * 2.0
