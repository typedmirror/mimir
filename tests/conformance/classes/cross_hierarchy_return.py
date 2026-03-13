from typing import assert_type

class Animal:
    pass

class Dog(Animal):
    pass

class Cat(Animal):
    pass

# Subclass is assignable to parent
def get_animal() -> Animal:
    return Dog()

r1 = get_animal()
assert_type(r1, Animal)

# Cross-hierarchy: Cat is not Dog
def wrong_return() -> Dog:
    return Cat()  # E
