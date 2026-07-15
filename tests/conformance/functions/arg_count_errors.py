# Function argument count checking
def f(x: int, y: str) -> None:
    pass

# Correct
f(1, "hello")

# Too few args
f(1)  # E[T004]

# Too many args
f(1, "hello", 42)  # E[T004]
