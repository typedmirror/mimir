# type(x) is T narrowing guard
def check_type(x: int | str) -> None:
    if type(x) is int:
        a: int = x
        b: str = x       # E[T001]
    else:
        c: str = x
        d: int = x       # E[T001]

def type_not(x: int | str) -> None:
    if type(x) is not int:
        e: str = x
        f: int = x       # E[T001]
