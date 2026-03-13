from typing import assert_type, Optional

# Compound `and` with two None checks — both narrow
def both_present(a: Optional[int], b: Optional[str]) -> bool:
    if a is not None and b is not None:
        assert_type(a, int)
        assert_type(b, str)
        return True
    return False
