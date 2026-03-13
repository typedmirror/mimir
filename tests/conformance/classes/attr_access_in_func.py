from typing import assert_type

class User:
    name: str
    age: int
    def __init__(self, name: str, age: int):
        self.name = name
        self.age = age

# Attr access through class constructed in function
def make_user_name() -> str:
    u = User("Alice", 30)
    return u.name

# Param type attr access
def get_user_age(u: User) -> int:
    return u.age
