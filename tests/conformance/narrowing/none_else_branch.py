from typing import assert_type

# is None positive → None, else → remainder
def check(x: int | None) -> int:
    if x is None:
        return 0
    assert_type(x, int)
    return x

# is not None → remainder in positive branch
def check2(x: str | None) -> str:
    if x is not None:
        assert_type(x, str)
        return x
    return "default"

# Nested: after None check, union narrows
def check3(x: int | str | None) -> None:
    if x is not None:
        bad: None = x  # E
