# Cross-function chain: A calls B, B's inferred return feeds A's return inference

from typing import assert_type

def make_greeting(name: str):
    return "Hello, " + name

def greet_user():
    return make_greeting("world")

msg = greet_user()
assert_type(msg, str)
