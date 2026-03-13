from typing import assert_type, Callable

# Callable parameter type checking in function
def apply_func(f: Callable[[int], str], x: int) -> str:
    result = f(x)
    assert_type(result, str)
    return result
