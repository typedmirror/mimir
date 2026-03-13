from typing import assert_type, Optional

# is None narrows to None in true branch
def handle_none(x: Optional[int]) -> int:
    if x is None:
        return 0
    # After None check, x is narrowed to int
    assert_type(x, int)
    return x

# is not None narrows to non-None in true branch
def handle_not_none(x: Optional[str]) -> str:
    if x is not None:
        assert_type(x, str)
        return x
    return ""
