# Virtual module: from mimir.array import works without filesystem module

from mimir.array import zeros, ones, array, matmul

a = zeros((3, 4))
b = ones((4, 5))
c = matmul(a, b)
d = array([1.0, 2.0, 3.0])
