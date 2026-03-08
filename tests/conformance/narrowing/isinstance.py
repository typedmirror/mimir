# isinstance narrowing conformance
# These should produce ZERO errors — narrowing guards the types

def check_type(x: int | str) -> str:
    if isinstance(x, int):
        return str(x)     # x is int here — ok
    else:
        return x          # x is str here — ok

def check_none(x: int | None) -> int:
    if isinstance(x, int):
        return x          # x is int here — ok
    return 0
