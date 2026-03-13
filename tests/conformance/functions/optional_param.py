from typing import assert_type, Optional

# Function with Optional parameter
def greet(name: Optional[str]) -> str:
    if name is not None:
        return "Hello, " + name
    return "Hello, stranger"

r = greet("Alice")
assert_type(r, str)

r2 = greet(None)
assert_type(r2, str)
