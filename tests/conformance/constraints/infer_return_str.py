# Function return type inferred from string operations

from typing import assert_type

def greet(name: str):
    return "Hello, " + name

msg = greet("world")
assert_type(msg, str)
