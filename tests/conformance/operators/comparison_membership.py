from typing import assert_type

# Chained comparison
x = 5
result = 1 < x < 10
assert_type(result, bool)

# Standard comparisons
a = 10 > 5
assert_type(a, bool)

b = "abc" == "def"
assert_type(b, bool)

c = 3.14 <= 4.0
assert_type(c, bool)

# Membership operators
d = 1 in [1, 2, 3]
assert_type(d, bool)

e = "x" not in "hello"
assert_type(e, bool)

# Identity operators
f = None is None
assert_type(f, bool)

g = 42 is not None
assert_type(g, bool)
