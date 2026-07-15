from typing import assert_type

def add(a: int, b: int) -> int:
    return a + b

def greet(name: str) -> str:
    return "Hello, " + name

# Correct calls
r1 = add(1, 2)
assert_type(r1, int)

r2 = greet("world")
assert_type(r2, str)

# Wrong argument type
add("a", "b")  # E[T002]
