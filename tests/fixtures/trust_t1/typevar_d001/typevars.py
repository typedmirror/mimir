"""T2 regression (FP3 protection): TypeVars used ONLY in annotations — every
variant — must never be flagged D001 unused. The genuinely-dead TypeVar and
variable at the bottom MUST be flagged (negative control)."""
from typing import Any, Callable, Generic, TypeVar

T = TypeVar("T")                                  # Generic base + methods
U = TypeVar("U")                                  # function annotations only
Q = TypeVar("Q")                                  # quoted annotations only
A = TypeVar("A")                                  # type-alias RHS only
F = TypeVar("F", bound=Callable[..., Any])        # decorator pattern (bound=)

Transform = Callable[[A], A]


class Box(Generic[T]):
    def __init__(self, item: T) -> None:
        self.item = item

    def get(self) -> T:
        return self.item


def swap(a: U, b: U) -> tuple[U, U]:
    return b, a


def quoted(x: "Q") -> "Q":
    return x


def wrap(fn: F) -> F:
    return fn


def apply(t: Transform, v: int) -> int:
    return t(v)


DEAD = TypeVar("DEAD")  # genuinely unused TypeVar — D001 correct here


def local_dead() -> int:
    unused_local = 41  # genuinely unused variable — D001 correct here
    return 42
