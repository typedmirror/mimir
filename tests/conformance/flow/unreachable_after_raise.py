# Unreachable code after raise
def check(x: int) -> int:
    if x < 0:
        raise ValueError("negative")
        y = 1  # E
    return x
