# WASM global variable tests

PI = 3.14159265358979
MAX_SIZE = 1024
THRESHOLD = 0.001
ZERO = 0

@wasm
def circle_area(r: float) -> float:
    return PI * r * r

@wasm
def is_within_bounds(x: int) -> int:
    if x < MAX_SIZE:
        return 1
    return 0

@wasm
def scale_to_max(x: int) -> int:
    return x * MAX_SIZE
