# Class scoping edge cases — should produce zero diagnostics

class Animal:
    species = "unknown"

    def __init__(self, name):
        self.name = name

    def describe(self):
        return f"{self.name} is a {self.species}"

class Dog(Animal):
    species = "canine"

    def bark(self):
        return "woof"

class Container:
    items = []

    class Inner:
        label = "inner"

        def get_label(self):
            return self.label

    def add(self, item):
        self.items.append(item)

def class_in_function():
    base_value = 10

    class LocalClass:
        def get_value(self):
            return base_value  # closure over function var

    return LocalClass()

class WithClassmethod:
    data = []

    @classmethod
    def create(cls):
        return cls()

    @staticmethod
    def helper():
        return 42

class WithProperties:
    def __init__(self):
        self._x = 0

    @property
    def x(self):
        return self._x

    @x.setter
    def x(self, value):
        self._x = value
