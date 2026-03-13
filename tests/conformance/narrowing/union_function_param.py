from typing import assert_type

# Narrowing union param inside function
def process(x: int | str | None) -> str:
    if x is None:
        return "none"
    if isinstance(x, int):
        assert_type(x, int)
        return str(x)
    assert_type(x, str)
    return x

# Nested narrowing with early return
def safe_len(x: str | None) -> int:
    if x is None:
        return 0
    assert_type(x, str)
    return len(x)
