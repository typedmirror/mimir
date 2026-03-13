from typing import assert_type

class Dog:
    name: str
    def __init__(self, name: str):
        self.name = name

class Cat:
    name: str
    def __init__(self, name: str):
        self.name = name

# Multiple class constructors in same function
def make_pets():
    d = Dog("Rex")
    c = Cat("Whiskers")
    assert_type(d, Dog)
    assert_type(c, Cat)
