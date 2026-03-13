from typing import assert_type

# Function with default parameters
def greet(name: str, greeting: str = "Hello") -> str:
    return greeting + " " + name

# Can call with or without default
r1 = greet("Alice")
assert_type(r1, str)

r2 = greet("Bob", "Hi")
assert_type(r2, str)

# Wrong type for non-default param
greet(42)  # E
