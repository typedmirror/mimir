from typing import assert_type, List

class Item:
    def __init__(self, name: str) -> None:
        self.name = name

# Typed list of class instances
items: List[Item] = [Item("a"), Item("b")]
first = items[0]
assert_type(first.name, str)
