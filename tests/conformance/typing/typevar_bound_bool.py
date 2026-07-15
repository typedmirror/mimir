from typing import TypeVar, assert_type

# TypeVar with bound — bool <: int satisfies int bound
T = TypeVar('T', bound=int)

def inc(x: T) -> T:
    return x

# Valid: int and bool both satisfy bound=int
r1 = inc(42)
assert_type(r1, int)

r2 = inc(True)

# Invalid: str doesn't satisfy int bound
inc("hello")  # E[T008]
