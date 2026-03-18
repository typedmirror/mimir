# Keyword arg caller→param inference: f(x=42) → x is int

def add(x, y):
    return x + y

# Keyword args provide type evidence for named params
result: str = add(x=1, y=2)  # E: Incompatible types
