from typing import assert_type

# Int arithmetic stays int
a = 10 + 5
assert_type(a, int)

b = 10 - 3
assert_type(b, int)

c = 10 * 3
assert_type(c, int)

# Float promotion on mixed
d = 10 + 3.14
assert_type(d, float)

# True division always float
e = 10 / 3
assert_type(e, float)

# Floor division stays int
f = 10 // 3
assert_type(f, int)

# Modulo preserves int
g = 10 % 3
assert_type(g, int)

# Power stays int
h = 2 ** 10
assert_type(h, int)

# Bool arithmetic promotes to int
i = True + True
assert_type(i, int)

j = True + 1
assert_type(j, int)

k = False * 5
assert_type(k, int)

# Bool in comparison stays bool
m = 10 > 5
assert_type(m, bool)

n = 3.14 <= 4.0
assert_type(n, bool)
