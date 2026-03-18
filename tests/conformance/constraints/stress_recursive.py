# Stress: recursive function — convergence should not infinite loop
# Known limitation: unannotated recursive return type includes Unknown

def factorial(n: int) -> int:
    if n <= 1:
        return 1
    return n * factorial(n - 1)

result: str = factorial(5)  # E: Incompatible types
