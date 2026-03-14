from typing import assert_type

# M07: Container element comparison via structural equality (not ID equality)
class Item:
    def __init__(self, name: str) -> None:
        self.name = name

def get_items() -> list[Item]:
    return [Item("a")]

items: list[Item] = get_items()
assert_type(items, list[Item])

# Dict with class values
def get_map() -> dict[str, Item]:
    return {"a": Item("a")}

m: dict[str, Item] = get_map()
assert_type(m, dict[str, Item])
