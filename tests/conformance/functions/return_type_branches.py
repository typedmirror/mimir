# Return type checked in all branches
def good(x: int) -> str:
    if x > 0:
        return "positive"
    else:
        return "non-positive"

def bad_branch(x: int) -> str:
    if x > 0:
        return "positive"
    else:
        return 42  # E[T003]

def bad_all(x: int) -> str:
    return x  # E[T003]
