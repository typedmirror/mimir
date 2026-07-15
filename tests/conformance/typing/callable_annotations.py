from typing import Callable, assert_type

# Callable[[int, str], bool] annotation
def apply(f: Callable[[int, str], bool], x: int, s: str) -> bool:
    return f(x, s)

cb: Callable[[int], str] = lambda x: str(x)
assert_type(cb, Callable[[int], str])

# Callable with no params
no_args: Callable[[], int] = lambda: 42
assert_type(no_args, Callable[[], int])

# Wrong type through Callable annotation
def takes_int_fn(f: Callable[[int], str]) -> None:
    pass

takes_int_fn(42)  # E[T002]
