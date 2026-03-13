from typing import assert_type

class Item:
    name: str
    def __init__(self, name: str):
        self.name = name

items = [Item("a"), Item("b")]

# Comprehension with class attr access
names = [i.name for i in items]
assert_type(names, list[str])
