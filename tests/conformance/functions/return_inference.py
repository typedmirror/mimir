from typing import assert_type

# Return type annotation propagates to caller
def square(x: int) -> int:
    return x * x

def to_str(x: int) -> str:
    return str(x)

# Chaining function calls
r = to_str(square(5))
assert_type(r, str)

# Wrong type from chained call
bad: int = to_str(42)  # E
