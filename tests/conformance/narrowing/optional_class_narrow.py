from typing import assert_type, Optional

class Data:
    value: int
    def __init__(self, value: int):
        self.value = value

# Optional narrowing + class attr access in function
def safe_get(d: Optional[Data]) -> int:
    if d is not None:
        assert_type(d, Data)
        return d.value
    return 0
