@wasm
def add_ints(a: int, b: int) -> int:
    return a + b

@wasm
def quadratic(x: float, a: float, b: float, c: float) -> float:
    return a * x * x + b * x + c

@wasm
def abs_diff(a: int, b: int) -> int:
    if a > b:
        return a - b
    else:
        return b - a
