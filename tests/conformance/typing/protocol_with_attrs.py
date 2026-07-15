from typing import Protocol

class Named(Protocol):
    name: str

class User:
    name: str
    def __init__(self, name: str) -> None:
        self.name = name

class Anon:
    pass

def greet(obj: Named) -> str:
    return obj.name

# Structural match — has name attr
greet(User("Alice"))

# No name attr
greet(Anon())  # E[T002]
