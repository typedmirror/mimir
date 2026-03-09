# Negated isinstance and None check narrowing
def not_instance(x: int | str) -> None:
    if not isinstance(x, int):
        a: str = x
        b: int = x       # E
    else:
        c: int = x

def not_none(x: int | None) -> None:
    if x is not None:
        d: int = x
    else:
        e: int = x       # E

def falsy(x: int | None) -> None:
    if not x:
        f: int = x       # E
    else:
        g: int = x
