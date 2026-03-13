from typing import assert_type

class Item:
    name: str
    def __init__(self, name: str):
        self.name = name

# List of class instances constructed in function
def make_items() -> list[Item]:
    items = [Item("a"), Item("b"), Item("c")]
    assert_type(items, list[Item])
    return items
