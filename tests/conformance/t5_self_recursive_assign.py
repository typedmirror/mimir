# T5 regression (S111 SIGSEGV): `-> Self` methods make Instance types
# equirecursive. Comparing two specializations of the same class (two distinct
# Type_IDs, same attrs) drove is_assignable into unbounded mutual recursion
# (attrs-fallback -> Callable covariant return -> Instance again). The cycle
# guard must terminate this — no crash AND no spurious errors on valid code.
from typing import Generic, Self, TypeVar

T = TypeVar("T")


class Chain(Generic[T]):
    def __init__(self, item: T) -> None:
        self.item = item

    def reset(self) -> Self:
        return self

    def touch(self) -> Self:
        return self.reset()


def take_int_chain(c: Chain[int]) -> Chain[int]:
    return c.reset()


def cross(a: Chain[int], b: Chain[str]) -> None:
    x = take_int_chain(a.reset().touch())
    y = b.reset().touch()
    print(x, y)
