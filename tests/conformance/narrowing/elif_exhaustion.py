from typing import assert_type

# Four-way union exhaustion via elif chain
def exhaustive(x: int | str | float | bool) -> None:
    if isinstance(x, bool):
        assert_type(x, bool)
        bad1: str = x  # E
    elif isinstance(x, int):
        assert_type(x, int)
        bad2: str = x  # E
    elif isinstance(x, str):
        assert_type(x, str)
        bad3: int = x  # E
    else:
        assert_type(x, float)
        bad4: int = x  # E
