# Container inference: for item in x → x is iterable (list)

def process(x):
    for item in x:
        pass
    return len(x)

# x used in for loop → iterable, len(x) → has __len__, returns int
result: str = process([1, 2, 3])  # E[T001]: Incompatible types
