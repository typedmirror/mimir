# Phase II: Arithmetic op constrains to numeric, then str assignment errors

def negate(x):
    y = -x
    result = x * 2
    z: str = x  # E[T001]: Incompatible types
