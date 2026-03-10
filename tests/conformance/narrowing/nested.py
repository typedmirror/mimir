def process(x: int | str | None) -> None:
    if isinstance(x, int):
        y: int = x  # OK — narrowed to int
        bad1: str = x  # E
    else:
        # x is str | None here
        if x is not None:
            y2: str = x  # OK — narrowed to str
            bad2: int = x  # E
        else:
            bad3: int = x  # E
