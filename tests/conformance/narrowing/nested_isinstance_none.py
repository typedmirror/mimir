from typing import assert_type

# Nested narrowing: isinstance inside is-None check
def nested(x: int | str | None) -> str:
    if x is not None:
        if isinstance(x, int):
            assert_type(x, int)
            return str(x)
        else:
            assert_type(x, str)
            return x
    return "none"

# Nested: None check inside isinstance
def nested2(x: int | None) -> int:
    if isinstance(x, int):
        assert_type(x, int)
        return x
    else:
        bad: int = x  # E
        return 0
