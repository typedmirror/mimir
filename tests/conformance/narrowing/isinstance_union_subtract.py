from typing import assert_type

# Else branch gets union with isinstance type subtracted
def process(x: int | str | float) -> None:
    if isinstance(x, int):
        assert_type(x, int)
    else:
        # Should be str | float
        bad: int = x  # E

def process2(x: int | str | None) -> None:
    if isinstance(x, int):
        r: int = x
    else:
        # Should be str | None
        bad: int = x  # E
