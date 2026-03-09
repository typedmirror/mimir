# Empty container contextual typing

# Empty list with annotation
x: list[int] = []

# Empty dict with annotation
d: dict[str, int] = {}

# Empty list in function arg
def process(items: list[str]) -> None:
    pass

process([])

# Empty list in return
def get_items() -> list[int]:
    return []

# Nested empty
nested: list[list[int]] = [[]]

# Conditional with empty
flag: bool = True
y: list[int] = [] if flag else [1, 2, 3]
