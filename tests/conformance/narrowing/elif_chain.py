from typing import assert_type

def check(x: int | str | float) -> None:
    if isinstance(x, int):
        assert_type(x, int)
        bad1: str = x  # E
    elif isinstance(x, str):
        assert_type(x, str)
        bad2: int = x  # E
    else:
        assert_type(x, float)
        bad3: int = x  # E
