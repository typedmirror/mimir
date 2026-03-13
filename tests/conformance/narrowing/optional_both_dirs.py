from typing import assert_type, Optional

# is None narrows, else branch gets the type
def process(x: Optional[int]) -> int:
    if x is None:
        return 0
    assert_type(x, int)
    return x + 1

# is not None narrows positively
def process2(x: Optional[str]) -> str:
    if x is not None:
        assert_type(x, str)
        return x
    return "default"
