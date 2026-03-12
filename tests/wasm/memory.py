@wasm
def byte_sum(data: bytes, n: int) -> int:
    total: int = 0
    for i in range(n):
        total = total + data[i]
    return total

@wasm
def dot_product(a: Tensor[float32, 1024], b: Tensor[float32, 1024], n: int) -> float32:
    total: float32 = 0.0
    for i in range(n):
        total = total + a[i] * b[i]
    return total
