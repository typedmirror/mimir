from typing import assert_type, Optional

# Nested narrowing: two Optional params
def deep_check(x: Optional[int], y: Optional[str]) -> str:
    if x is not None:
        assert_type(x, int)
        if y is not None:
            assert_type(y, str)
            return str(x) + y
        return str(x)
    return "none"
