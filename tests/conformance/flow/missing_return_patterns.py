from typing import assert_type

# No return statement at all
def no_return() -> int:  # E
    x = 42

# Return None when int expected
def none_return() -> int:
    return None  # E

# Correct: returns in all paths
def ok_return(x: bool) -> int:
    if x:
        return 1
    else:
        return 0
