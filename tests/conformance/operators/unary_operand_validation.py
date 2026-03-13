from typing import assert_type

# Valid unary operations
a = -42
assert_type(a, int)
b = -3.14
assert_type(b, float)
c = ~5
assert_type(c, int)
d = +True
assert_type(d, int)

# Invalid unary operations
x = -"hello"  # E
y = ~"text"  # E
z = -[1, 2]  # E
