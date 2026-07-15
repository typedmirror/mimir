# Assert isinstance narrowing

def process(x: int | str) -> None:
    assert isinstance(x, int)
    y: str = x  # E[T001]: Incompatible types
