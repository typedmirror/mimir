from typing import assert_type, Optional

# Walrus operator with is not None narrowing
def process(data: Optional[str]) -> str:
    if (x := data) is not None:
        assert_type(x, str)
        return x
    return "default"

# Walrus with int Optional
def process_int(data: Optional[int]) -> int:
    if (y := data) is not None:
        assert_type(y, int)
        return y
    return 0
