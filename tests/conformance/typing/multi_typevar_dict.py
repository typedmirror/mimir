from typing import assert_type, TypeVar

K = TypeVar('K')
V = TypeVar('V')

# Multiple TypeVars with dict parameter
def first_key(d: dict[K, V]) -> K:
    for k in d:
        return k
    raise ValueError("empty")

def first_value(d: dict[K, V]) -> V:
    for v in d.values():
        return v
    raise ValueError("empty")
