from typing import assert_type, Callable

def apply(f: Callable[[int], str], x: int) -> str:
    return f(x)

result = apply(str, 42)
assert_type(result, str)

# Wrong argument type to higher-order function
apply(str, "not_int")  # E[T002]
