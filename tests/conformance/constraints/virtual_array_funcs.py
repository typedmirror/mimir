# Virtual module: all creation functions resolve

from mimir.array import zeros, ones, arange, linspace, reshape, sum, mean, transpose

a = zeros((3, 4))
b = ones((4, 5))
c = arange(0, 10)
d = linspace(0.0, 1.0, 100)
e = reshape(a, (12,))
f = sum(a)
g = mean(b)
h = transpose(a)
