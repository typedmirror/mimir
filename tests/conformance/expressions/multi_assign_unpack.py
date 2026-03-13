from typing import assert_type

# Tuple unpacking
t = (1, "hello")
a, b = t

# Multi-target same value
x = y = 42
assert_type(x, int)
assert_type(y, int)
