# Container inference: x.append(42) → x is list[int]

def collect(x):
    x.append(42)
    return x

result: str = collect([1, 2])  # E: Incompatible types
