"""Typed JSON read — mimir.json.read with schema returns typed result."""
from mimir.json import read
from typing import TypedDict, assert_type

class User(TypedDict):
    name: str
    age: int

user = read("user.json", User)
assert_type(user["name"], str)
assert_type(user["age"], int)
