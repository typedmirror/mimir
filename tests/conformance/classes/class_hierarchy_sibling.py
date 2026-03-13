from typing import assert_type

class Animal:
    def __init__(self, name: str) -> None:
        self.name = name

    def speak(self) -> str:
        return self.name

class Dog(Animal):
    def speak(self) -> str:
        return "Woof"

class Cat(Animal):
    def speak(self) -> str:
        return "Meow"

d = Dog("Rex")
c = Cat("Whiskers")

# Inherited attribute
assert_type(d.name, str)

# Overridden method
assert_type(d.speak(), str)
assert_type(c.speak(), str)

# Subclass assignable to parent
parent: Animal = d

# Sibling classes not interchangeable
bad: Cat = d  # E
