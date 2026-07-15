from typing import assert_type

def check(x: int | str | float) -> None:
    if isinstance(x, int):
        assert_type(x, int)
        bad1: str = x  # E[T001]
    elif isinstance(x, str):
        assert_type(x, str)
        bad2: int = x  # E[T001]
    else:
        assert_type(x, float)
        bad3: int = x  # E[T001]
