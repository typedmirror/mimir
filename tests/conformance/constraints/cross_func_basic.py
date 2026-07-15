# Cross-function: helper's return type propagates to caller

def helper(x: int):
    return x + 1

def caller():
    result = helper(42)
    y: str = result  # E[T001]: Incompatible types
