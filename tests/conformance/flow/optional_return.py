from typing import assert_type, Optional

# Function returning Optional[T]
def find(x: int) -> Optional[str]:
    if x > 0:
        return "found"
    return None

r = find(5)
assert_type(r, Optional[str])

# Wrong return in Optional function
def bad_find(x: int) -> Optional[str]:
    if x > 0:
        return 42  # E
    return None
