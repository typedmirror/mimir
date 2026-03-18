# TypeGuard: custom type narrowing functions

from typing import TypeGuard

def is_str(x: object) -> TypeGuard[str]:
    return isinstance(x, str)

val: object = "hello"
if is_str(val):
    result: int = val  # E: Incompatible types
