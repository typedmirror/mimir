# Negated isinstance and None check narrowing
def not_instance(x: int | str) -> None:
    if not isinstance(x, int):
        a: str = x
        b: int = x       # E[T001]
    else:
        c: int = x

def not_none(x: int | None) -> None:
    if x is not None:
        d: int = x
    else:
        e: int = x       # E[T001]

def falsy(x: int | None) -> None:
    if not x:
        f: int = x       # E[T001]
    else:
        g: int = x
