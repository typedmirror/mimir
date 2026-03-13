from typing import assert_type, Optional

# assert_type in both branches of Optional narrowing
def describe(x: Optional[int]) -> str:
    if x is None:
        assert_type(x, None)
        return "nothing"
    else:
        assert_type(x, int)
        return "something"
