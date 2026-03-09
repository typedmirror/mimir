# Multi-member union narrowing in else branch
from typing import Union

def narrow_union(x: Union[int, str, float]) -> None:
    if isinstance(x, int):
        a: int = x
    else:
        b: str = x       # E  — still str | float, not just str
        c: float = x     # E  — still str | float, not just float
