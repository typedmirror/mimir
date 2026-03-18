# Callable constraint: f(x) where f is unannotated param → f is Callable

def apply(f, x: int) -> int:
    return f(x)

# apply's return annotated as int, f(x) call resolves f to Callable[[int], Any]
# apply(str, 42) works — str is callable
result = apply(str, 42)
