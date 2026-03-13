from typing import assert_type

class User:
    def __init__(self, name: str):
        self.name = name

def make_user(name: str) -> User:
    return User(name)

# Return wrong type for user class
def bad_return(name: str) -> User:
    return "not a user"  # E

u = make_user("Alice")
assert_type(u, User)
