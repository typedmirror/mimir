from typing import assert_type

class Animal:
    def speak(self) -> str:
        return "..."

class Dog(Animal):
    def speak(self) -> str:
        return "woof"

class Cat(Animal):
    def speak(self) -> str:
        return "meow"

# Subclass passes where parent expected
def make_sound(a: Animal) -> str:
    return a.speak()

r1 = make_sound(Dog())
assert_type(r1, str)

r2 = make_sound(Cat())
assert_type(r2, str)

# Wrong type entirely
make_sound(42)  # E[T002]
