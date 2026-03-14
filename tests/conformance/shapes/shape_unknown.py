"""Shape validation: graceful degradation with unknown shapes."""

from mimir.array import zeros, matmul

# Dynamic shape — no error (can't validate)
def f(n):
    a = zeros((n, 4))
    b = zeros((4, 5))
    c = matmul(a, b)    # OK: inner dim of a is unknown
