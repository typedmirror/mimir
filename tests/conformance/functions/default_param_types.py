from typing import assert_type

def process(data: list[int], result: list[int] = []) -> list[int]:
    for item in data:
        result.append(item)
    return result

r = process([1, 2, 3])
assert_type(r, list[int])

# Default with Optional
def greet(name: str = "world") -> str:
    return f"Hello, {name}"

g = greet()
assert_type(g, str)

g2 = greet("Alice")
assert_type(g2, str)
