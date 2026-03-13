from typing import assert_type, Protocol, Callable

# Protocol structural subtyping
class Handler(Protocol):
    def handle(self, data: str) -> int:
        return 0

class MyHandler:
    def handle(self, data: str) -> int:
        return len(data)

h: Handler = MyHandler()

# Callable higher-order
def apply(f: Callable[[int], str], x: int) -> str:
    return f(x)

def to_str(n: int) -> str:
    return str(n)

r = apply(to_str, 42)
assert_type(r, str)

# Wrong callable
def wrong_type(n: str) -> str:
    return n

apply(wrong_type, 42)  # E
