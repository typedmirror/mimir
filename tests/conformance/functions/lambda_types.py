from typing import Callable, assert_type

# Lambda type inference
f = lambda x: x + 1

# Lambda as Callable
g: Callable[[int], str] = lambda x: str(x)
assert_type(g, Callable[[int], str])

# Lambda with no args
h: Callable[[], int] = lambda: 42
assert_type(h, Callable[[], int])

# Lambda as function argument
def apply(func: Callable[[int], int], val: int) -> int:
    return func(val)

result = apply(lambda x: x * 2, 5)
assert_type(result, int)
