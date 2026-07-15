def multi_dead() -> int:
    return 1
    x = 2    # E[F001]: unreachable
    y = 3    # E[F001]: unreachable
    return 4 # E[F001]: unreachable

def multi_after_raise() -> None:
    raise ValueError()
    a = 1    # E[F001]: unreachable
    b = 2    # E[F001]: unreachable
