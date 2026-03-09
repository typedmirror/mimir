# For loop return and element typing
def search(xs: list[int], target: int) -> str:
    for x in xs:
        if x == target:
            return "found"
    return "not found"

a: str = search([1, 2], 1)
b: int = search([1, 2], 1)   # E

# For loop element typing
items: list[str] = ["a", "b"]
for item in items:
    c: str = item
    d: int = item             # E
