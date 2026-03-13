from typing import assert_type

class Inner:
    val: int
    def __init__(self, val: int):
        self.val = val

class Outer:
    inner: Inner
    def __init__(self, inner: Inner):
        self.inner = inner

# Chained attr access through composed classes in function
def get_deep_val() -> int:
    o = Outer(Inner(42))
    return o.inner.val
