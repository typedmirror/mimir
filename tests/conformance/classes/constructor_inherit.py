class Animal:
    name: str
    def __init__(self, name: str) -> None:
        self.name = name

class Dog(Animal):
    breed: str
    def __init__(self, name: str, breed: str) -> None:
        self.name = name
        self.breed = breed

# Parent constructor
a = Animal("Rex")

# Child constructor — correct
d = Dog("Rex", "Lab")

# Wrong arg count for parent
Animal()  # E

# Wrong arg count for child
Dog("Rex")  # E

# Wrong arg type
Animal(42)  # E
