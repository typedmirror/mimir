def multi_dead() -> int:
    return 1
    x = 2    # E: unreachable
    y = 3    # E: unreachable
    return 4 # E: unreachable

def multi_after_raise() -> None:
    raise ValueError()
    a = 1    # E: unreachable
    b = 2    # E: unreachable
