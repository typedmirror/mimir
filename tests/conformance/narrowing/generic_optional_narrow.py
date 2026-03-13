from typing import assert_type, TypeVar, Generic, Optional

T = TypeVar('T')

class Box(Generic[T]):
    def __init__(self, val: T) -> None:
        self.val = val

# Generic class preserves type arg
b = Box(42)
assert_type(b.val, int)

# Optional narrowing with is not None
def unwrap(x: Optional[int]) -> int:
    if x is not None:
        assert_type(x, int)
        return x
    return 0
