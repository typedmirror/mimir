from typing import assert_type

class Animal:
    def __init__(self, name: str) -> None:
        self.name = name

    def speak(self) -> str:
        return "..."

class Dog(Animal):
    def __init__(self, name: str, breed: str) -> None:
        self.name = name
        self.breed = breed

    def speak(self) -> str:
        return "woof"

class Cat(Animal):
    def speak(self) -> str:
        return "meow"

# Correct constructor usage
d = Dog("Rex", "Lab")
assert_type(d, Dog)
assert_type(d.breed, str)
assert_type(d.speak(), str)

# Parent constructor
c = Cat("Whiskers")
assert_type(c, Cat)
assert_type(c.name, str)

# Wrong arg count
Dog("Rex")  # E[T004]
