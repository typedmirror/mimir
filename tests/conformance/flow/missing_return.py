# Missing return statement detection (F002)
def missing(x: int) -> int:    # E[F002]
    if x > 0:
        return x

def ok(x: int) -> int:
    if x > 0:
        return x
    else:
        return -x

def no_annotation(x: int):
    if x > 0:
        return x
    # no error — no return annotation

def always_returns(x: int) -> int:
    return x

def missing_else(x: bool) -> str:    # E[F002]
    if x:
        return "yes"

def multi_branch(x: int) -> str:    # E[F002]
    if x > 0:
        return "pos"
    elif x == 0:
        return "zero"
    # missing negative case
