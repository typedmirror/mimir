from typing import assert_type, Optional, Union

# Optional[Optional[int]] flattens to Optional[int]
def unwrap(x: Optional[Optional[int]]) -> int:
    if x is not None:
        assert_type(x, int)
        return x
    return 0

# Union[int, None] equivalent to Optional[int]
def process(x: Union[int, None]) -> int:
    if x is not None:
        assert_type(x, int)
        return x
    return 0
