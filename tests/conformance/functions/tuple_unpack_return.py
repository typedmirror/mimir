from typing import assert_type

def swap_pair(a: int, b: str) -> tuple[str, int]:
    return (b, a)

# Tuple unpacking from function return
def use_swap():
    x, y = swap_pair(1, "hello")
    assert_type(x, str)
    assert_type(y, int)
