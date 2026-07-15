# Inferred return type should catch type mismatches at call site

def make_list(x: int):
    return [x]

result: int = make_list(5)  # E[T001]: Incompatible types
