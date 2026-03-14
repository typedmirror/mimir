# Phase II: Call-site Type_Subtype — passing x to a typed parameter

def accept_int(n: int) -> int:
    return n + 1

def process(x):
    result = accept_int(x)
    # x must be int (from accept_int's param type)
    y: str = x  # E: Incompatible types
