from typing import assert_type, Optional

# Walrus + isinstance compound narrowing via `and`
def test(x: Optional[str]):
    if (y := x) and isinstance(y, str):
        assert_type(y, str)
