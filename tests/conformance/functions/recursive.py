from typing import assert_type

# Recursive function with type annotations
def factorial(n: int) -> int:
    if n <= 1:
        return 1
    return n * factorial(n - 1)

r = factorial(5)
assert_type(r, int)

# Recursive with wrong base case return type
def bad_rec(n: int) -> str:
    if n <= 0:
        return 42  # E
    return "ok"
