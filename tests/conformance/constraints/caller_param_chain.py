# Chain inference: f calls g, g's return inferred, enables f's caller check

def add_one(x: int) -> int:
    return x + 1

def double_add(x):
    return add_one(x) + add_one(x)

# double_add body: add_one(x) returns int → double_add returns int
result: str = double_add(5)  # E: Incompatible types
