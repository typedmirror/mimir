# Unreachable code detection (F001)
def after_return() -> int:
    return 1
    x = 2              # E[F001]

def after_raise() -> None:
    raise ValueError()
    x = 2              # E[F001]

def branch_ok(x: bool) -> int:
    if x:
        return 1
    else:
        return 2
    # no error — all paths return before here, but dead code only if stmt follows

def loop_break() -> None:
    for i in [1, 2]:
        break
        x = 2          # E[F001]

def loop_continue() -> None:
    for i in [1, 2]:
        continue
        x = 2          # E[F001]
