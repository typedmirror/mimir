# Call argument count conformance

def zero_args() -> int:
    return 0

def one_arg(x: int) -> int:
    return x

def two_args(a: int, b: int) -> int:
    return a + b

# Correct — no errors
zero_args()
one_arg(1)
two_args(1, 2)

# Too many arguments
zero_args(1)       # E[T004]: too many arguments
one_arg(1, 2)      # E[T004]: too many arguments
two_args(1, 2, 3)  # E[T004]: too many arguments

# Too few arguments
one_arg()          # E[T004]: too few arguments
two_args(1)        # E[T004]: too few arguments
