from typing import assert_type, Callable

# Callable as return type of function
def get_adder() -> Callable[[int, int], int]:
    def add(a: int, b: int) -> int:
        return a + b
    return add

f = get_adder()
r = f(1, 2)
assert_type(r, int)
