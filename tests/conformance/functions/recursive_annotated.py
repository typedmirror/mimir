from typing import assert_type

def factorial(n: int) -> int:
    if n <= 1:
        return 1
    return n * factorial(n - 1)

result = factorial(5)
assert_type(result, int)

def fib(n: int) -> int:
    if n <= 1:
        return n
    return fib(n - 1) + fib(n - 2)

fib_result = fib(10)
assert_type(fib_result, int)
