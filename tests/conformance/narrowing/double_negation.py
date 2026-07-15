from typing import assert_type

# Double negation: not (not isinstance(...))
def double_neg(x: int | str) -> None:
    if not isinstance(x, str):
        assert_type(x, int)
        bad: str = x  # E[T001]
    else:
        assert_type(x, str)
        bad2: int = x  # E[T001]
