from typing import Callable, assert_type

# Higher-order: function taking a callback
def apply(f: Callable[[int], str], x: int) -> str:
    return f(x)

def int_to_str(x: int) -> str:
    return str(x)

result = apply(int_to_str, 42)
assert_type(result, str)

# Wrong callback type
def bad_cb(x: str) -> str:
    return x

apply(bad_cb, 42)  # E

# Wrong callback return type
def bad_ret(x: int) -> int:
    return x

apply(bad_ret, 42)  # E
