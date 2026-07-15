from typing import assert_type, Callable

def double(x: int) -> int:
    return x * 2

# Function as Callable value
f: Callable[[int], int] = double

# Wrong callable signature
g: Callable[[str], str] = double  # E[T001]
