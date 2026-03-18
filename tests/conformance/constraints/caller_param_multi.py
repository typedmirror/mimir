# Multi-round convergence: f calls g, g's inferred return enables f's return inference

def helper(x: int) -> int:
    return x + 1

def middle(y):
    return helper(y)

# Round 1: middle(5) → y gets int from caller. helper(y) → returns int.
# middle's return type inferred as int.
result: str = middle(5)  # E: Incompatible types
