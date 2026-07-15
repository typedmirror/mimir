# Inheritance subtyping conformance

class Animal:
    name: str
    def __init__(self, name: str):
        self.name = name

class Dog(Animal):
    breed: str
    def __init__(self, name: str, breed: str):
        self.name = name
        self.breed = breed

# Subclass assignable to superclass — no errors
a: Animal = Dog("Rex", "Lab")

# Superclass NOT assignable to subclass
bad1: Dog = Animal("Rex")   # E[T001]
