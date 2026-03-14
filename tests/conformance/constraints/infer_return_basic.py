# Function return type inferred from body

from typing import assert_type

def add(x: int, y: int):
    return x + y

result = add(1, 2)
assert_type(result, int)
