from typing import assert_type, Union

# Early return narrows remaining code
def process(x: Union[int, str]) -> int:
    if isinstance(x, str):
        return len(x)
    # After early return, x is narrowed to int
    assert_type(x, int)
    return x * 2
