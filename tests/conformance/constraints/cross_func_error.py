# Cross-function: inferred return type catches error at module-level call site

def compute(x: int):
    return x * 2

def wrapper():
    return compute(10)

result: str = wrapper()  # E[T001]: Incompatible types
