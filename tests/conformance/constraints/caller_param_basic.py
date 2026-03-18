# Caller→param inference: f(42) → f's unannotated param is int

def double(x):
    return x * 2

# Caller provides int evidence, return type inferred as int
result: str = double(42)  # E: Incompatible types
