from typing import assert_type, Optional

# Optional return from conditional
def safe_div(a: int, b: int) -> Optional[float]:
    if b == 0:
        return None
    return a / b
