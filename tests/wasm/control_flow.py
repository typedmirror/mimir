@wasm
def factorial(n: int) -> int:
    result: int = 1
    i: int = 1
    while i <= n:
        result = result * i
        i = i + 1
    return result

@wasm
def sum_range(n: int) -> int:
    total: int = 0
    for i in range(n):
        total = total + i
    return total

@wasm
def clamp(x: int, lo: int, hi: int) -> int:
    if x < lo:
        return lo
    if x > hi:
        return hi
    return x
