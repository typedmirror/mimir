from typing import assert_type

# Bare return from -> None is fine
def cleanup() -> None:
    x = 42
    return

# pass body from -> None is fine
def noop() -> None:
    pass

# Wrong — returning value from -> None
def bad_cleanup() -> None:
    return "done"  # E[T003]
