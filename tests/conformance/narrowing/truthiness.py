# Truthiness narrowing removes None
x: int | None = 42
if x:
    y: int = x  # x narrowed to int (None removed)

val: str | None = "hello"
if val is not None:
    z: str = val  # narrowed to str
