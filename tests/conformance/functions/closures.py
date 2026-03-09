# Closure variable types
def outer() -> None:
    x: int = 42

    def inner() -> int:
        return x

    a: int = inner()
    b: str = inner()     # E

def make_adder(n: int):
    def add(x: int) -> int:
        return x + n
    return add

f = make_adder(10)
c: int = f(5)
# d: str = f(5) — not tested: make_adder has no return annotation → f is UNKNOWN
