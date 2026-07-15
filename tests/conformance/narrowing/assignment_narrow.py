def check(x: int | str) -> None:
    if isinstance(x, int):
        y: int = x  # OK — narrowed to int
        bad1: str = x  # E[T001]
    else:
        bad2: int = x  # E[T001]
