"""Basic test file for the parser."""

import os
from typing import List, Optional


def greet(name: str, times: int = 1) -> str:
    """Greet someone multiple times."""
    result = []
    for i in range(times):
        result.append(f"Hello, {name}!")
    return "\n".join(result)


class Counter:
    def __init__(self, start: int = 0):
        self.value = start

    def increment(self) -> None:
        self.value += 1

    def __repr__(self) -> str:
        return f"Counter({self.value})"


x: int = 42
y = x + 1
z = [i**2 for i in range(10)]
w = {k: v for k, v in enumerate(z)}

if x > 0:
    print("positive")
elif x == 0:
    print("zero")
else:
    print("negative")

try:
    result = 1 / 0
except ZeroDivisionError as e:
    print(f"caught: {e}")
finally:
    print("done")

a, b, *rest = [1, 2, 3, 4, 5]
flag = True if a > 0 else False
value = a if a is not None else b

assert x == 42, "x should be 42"

del y

global_var = None

lambda_fn = lambda x, y: x + y

async def fetch(url: str) -> bytes:
    pass

with open("test.txt") as f:
    data = f.read()

while False:
    break
    continue
