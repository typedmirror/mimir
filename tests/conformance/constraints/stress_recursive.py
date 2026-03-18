# Recursive function: return type filters out Unknown from recursive calls

def factorial(n):
    if n <= 1:
        return 1
    return n * factorial(n - 1)

# factorial returns int (not int | Unknown)
result: str = factorial(5)  # E: Incompatible types
