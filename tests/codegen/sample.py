import os
from typing import Optional

MAX_SIZE: int = 100

def add(x: int, y: int) -> int:
    return x + y

def greet(name: str) -> str:
    return "Hello, " + name

def maybe_int(x: Optional[int]) -> bool:
    return x is not None

class Counter:
    count: int

    def __init__(self, start: int) -> None:
        self.count = start

    def increment(self) -> None:
        self.count += 1

    def get_count(self) -> int:
        return self.count

    def reset(self) -> None:
        self.count = 0
