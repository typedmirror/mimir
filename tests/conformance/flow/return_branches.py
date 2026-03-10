def missing_return(x: int) -> int:  # E
    if x > 0:
        return x

def wrong_return() -> int:
    return "oops"  # E

def branch_mismatch(x: bool) -> int:
    if x:
        return 1
    else:
        return "no"  # E
