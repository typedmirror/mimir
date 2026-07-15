from typing import assert_type

def greet(name: str, greeting: str) -> str:
    return greeting + " " + name

# Positional call
r1 = greet("Alice", "Hello")
assert_type(r1, str)

# Keyword call
r2 = greet(name="Bob", greeting="Hi")
assert_type(r2, str)

# Mixed positional + keyword
r3 = greet("Charlie", greeting="Hey")
assert_type(r3, str)

# Wrong keyword type
greet(name=42, greeting="Hi")  # E[T002]
