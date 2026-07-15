# Assert is not None narrowing

from typing import Optional

def require(x: Optional[int]) -> int:
    assert x is not None
    return x  # OK — narrowed to int

def bad(x: Optional[int]) -> str:
    assert x is not None
    return x  # E[T003]: Incompatible return value type
