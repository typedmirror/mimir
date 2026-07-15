# §3.4: Single caller pattern — no specialization needed, should not regress

def double(x):
    return x * 2

# Only one call pattern — specialization skips (len < 2 guard)
result = double(5)

# Should still work via convergence loop (single caller inference)
y: int = double(10)

# This should error via convergence (return int, not str)
z: str = double(10)  # E[T001]: Incompatible types
