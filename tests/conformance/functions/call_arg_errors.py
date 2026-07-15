from typing import assert_type

def greet(name: str, times: int) -> str:
    return name * times

# Correct call
r = greet("hi", 3)
assert_type(r, str)

# Too few arguments
greet("hi")  # E[T004]

# Too many arguments
greet("hi", 3, True)  # E[T004]

# Wrong argument types
greet(42, 3)  # E[T002]
greet("hi", "three")  # E[T002]
