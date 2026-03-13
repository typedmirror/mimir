from typing import assert_type, Optional

# Early return narrows remainder
def process(x: Optional[int]) -> int:
    if x is None:
        return 0
    # After early return, x is narrowed to int
    assert_type(x, int)
    return x * 2
