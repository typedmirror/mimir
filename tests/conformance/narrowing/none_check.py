# None narrowing conformance
# These should produce ZERO errors — None checks narrow the type

def process(x: int | None) -> int:
    if x is not None:
        return x       # x is int here — ok
    return 0

def process2(x: str | None) -> str:
    if x is None:
        return "default"
    return x           # x is str here — ok
