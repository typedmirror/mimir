# Container inference: x.add(42) → x is set[int]

def register(x):
    x.add(42)

result: str = register({1, 2})  # E[T001]: Incompatible types
