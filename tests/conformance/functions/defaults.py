# Default parameter handling conformance

def with_default(x: int, y: int = 10) -> int:
    return x + y

def all_defaults(a: int = 1, b: int = 2) -> int:
    return a + b

# Correct — no errors
with_default(5)
with_default(5, 20)
all_defaults()
all_defaults(10)
all_defaults(10, 20)

# Too many arguments
with_default(1, 2, 3)    # E[T004]: too many arguments
all_defaults(1, 2, 3)    # E[T004]: too many arguments

# Too few arguments
with_default()           # E[T004]: too few arguments
