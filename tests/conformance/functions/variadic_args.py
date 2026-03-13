from typing import assert_type

# *args with type annotation
def sum_all(*args: int) -> int:
    return sum(args)

r = sum_all(1, 2, 3)
assert_type(r, int)

# **kwargs not tested (checker limitation for kwargs type)
