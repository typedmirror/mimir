from typing import assert_type
from dataclasses import dataclass

@dataclass
class User:
    name: str
    age: int = 0
    active: bool = True

# All args provided
u1 = User(name="Alice", age=30, active=False)
assert_type(u1, User)

# Using defaults (only required field)
u2 = User(name="Bob")
assert_type(u2.name, str)
assert_type(u2.age, int)
assert_type(u2.active, bool)

# Wrong type for required field
User(name=42)  # E
