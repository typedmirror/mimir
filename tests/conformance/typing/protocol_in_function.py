from typing import assert_type, Protocol

class HasName(Protocol):
    name: str

class Person:
    name: str
    def __init__(self, name: str):
        self.name = name

# Protocol parameter + class construction in function
def greet(obj: HasName) -> str:
    return obj.name

def test():
    p = Person("Alice")
    r = greet(p)
    assert_type(r, str)
