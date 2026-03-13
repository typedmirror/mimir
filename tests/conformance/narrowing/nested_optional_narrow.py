from typing import assert_type, Optional

# Nested narrowing: both params
def nested(x: Optional[int], y: Optional[str]) -> str:
    if x is not None:
        if y is not None:
            assert_type(x, int)
            assert_type(y, str)
            return str(x) + y
        return str(x)
    return ""
