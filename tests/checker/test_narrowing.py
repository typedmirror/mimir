# Narrowing type checking test — isinstance and None narrowing
# Expected: 0 errors (all valid after narrowing)

def process(x: int | str) -> int:
    if isinstance(x, int):
        return x          # ok: x narrowed to int
    return 0              # fallback

def maybe(x: int | None) -> int:
    if x is None:
        return 0
    return x              # ok: x narrowed to int (None removed)

def check_truthy(x: str | None) -> str:
    if x:
        return x          # ok: x narrowed (None removed)
    return "default"
