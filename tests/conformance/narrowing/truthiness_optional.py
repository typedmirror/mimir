from typing import assert_type

# Truthiness narrows Optional by removing None
def check_opt_str(x: str | None) -> str:
    if x:
        assert_type(x, str)
        return x
    return "default"

def check_opt_int(x: int | None) -> int:
    if x:
        assert_type(x, int)
        return x
    return 0

# Inverted truthiness
def check_not(x: str | None) -> str:
    if not x:
        return "falsy"
    assert_type(x, str)
    return x
