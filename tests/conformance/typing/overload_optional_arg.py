from typing import overload, assert_type

@overload
def greet(name: str) -> str: ...
@overload
def greet(name: str, greeting: str) -> str: ...
def greet(name, greeting="Hello"):
    return f"{greeting}, {name}!"

x = greet("Alice")
assert_type(x, str)

y = greet("Bob", "Hi")
assert_type(y, str)
