from typing import assert_type

# Three levels of nesting
def outer() -> int:
    def middle() -> str:
        def inner() -> float:
            return 3.14
        return str(inner())
    return len(middle())

result = outer()
assert_type(result, int)

# Closure capturing outer variable
def make_adder(n: int):
    def add(x: int) -> int:
        return x + n
    return add

# Wrong return type in deeply nested function
def bad_outer() -> int:
    def bad_middle() -> str:
        def bad_inner() -> int:
            return "wrong"  # E[T003]
        return "ok"
    return 0
