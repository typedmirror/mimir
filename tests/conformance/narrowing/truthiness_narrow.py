from typing import assert_type, Optional

# Truthiness narrows Optional to non-None
def check(x: Optional[str]) -> str:
    if x:
        assert_type(x, str)
        return x
    return ""

# Negated truthiness
def check2(x: Optional[int]) -> int:
    if not x:
        return 0
    assert_type(x, int)
    return x
