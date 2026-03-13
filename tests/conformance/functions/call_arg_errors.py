from typing import assert_type

def greet(name: str, times: int) -> str:
    return name * times

# Correct call
r = greet("hi", 3)
assert_type(r, str)

# Too few arguments
greet("hi")  # E

# Too many arguments
greet("hi", 3, True)  # E

# Wrong argument types
greet(42, 3)  # E
greet("hi", "three")  # E
