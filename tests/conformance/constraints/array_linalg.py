from typing import assert_type
from mimir.array import zeros, matmul, dot, solve, inv, det, norm, eig, svd

a = zeros((3, 3))
b = zeros((3, 3))

# matmul
c = matmul(a, b)

# dot product
d = dot(a, b)

# solve
x = solve(a, b)

# inverse
ai = inv(a)

# determinant → scalar float
dt = det(a)
assert_type(dt, float)

# norm → scalar float
n = norm(a)
assert_type(n, float)

# eigenvalues → tuple of (values, vectors)
vals, vecs = eig(a)

# SVD → tuple of (U, S, V)
u, s, v = svd(a)
