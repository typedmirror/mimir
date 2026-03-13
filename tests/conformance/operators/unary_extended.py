from typing import assert_type

# Valid unary on bool (promotes to int)
a = -True
assert_type(a, int)

b = +False
assert_type(b, int)

# Bitwise on bool
c = ~True
assert_type(c, int)

# String multiplication
s = "ha" * 3
assert_type(s, str)

# Invalid unary on string
bad1 = -"hello"  # E
bad2 = ~"world"  # E
