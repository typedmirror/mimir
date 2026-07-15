from typing import assert_type

# Valid -> None function
def void_func() -> None:
    pass

def also_void() -> None:
    x = 42
    return

# Returning a value from -> None function is an error
def bad_void() -> None:
    return 42  # E[T003]
