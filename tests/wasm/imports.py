# WASM import tests — host function calls

import math

@wasm
def print_value(x: int) -> int:
    print(x)
    return x

@wasm
def compute_sin(x: float) -> float:
    return math.sin(x)

@wasm
def compute_cos(x: float) -> float:
    return math.cos(x)

@wasm
def compute_exp(x: float) -> float:
    return math.exp(x)

@wasm
def compute_log(x: float) -> float:
    return math.log(x)

@wasm
def compute_pow(base: float, exp: float) -> float:
    return math.pow(base, exp)

@wasm
def compute_sqrt_native(x: float) -> float:
    # sqrt uses native WASM instruction, not import
    return math.sqrt(x)

@wasm
def compute_floor_native(x: float) -> float:
    # floor uses native WASM instruction
    return math.floor(x)

@wasm
def compute_ceil_native(x: float) -> float:
    # ceil uses native WASM instruction
    return math.ceil(x)

@wasm
def hypotenuse(a: float, b: float) -> float:
    return math.sqrt(a * a + b * b)
