# type(x) is T narrowing guard
def check_type(x: int | str) -> None:
    if type(x) is int:
        a: int = x
        b: str = x       # E
    else:
        c: str = x
        d: int = x       # E

def type_not(x: int | str) -> None:
    if type(x) is not int:
        e: str = x
        f: int = x       # E
