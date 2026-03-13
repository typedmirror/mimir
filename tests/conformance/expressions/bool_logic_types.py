from typing import assert_type

# Boolean logic operations
a = True and False
assert_type(a, bool)

b = True or False
assert_type(b, bool)

c = not True
assert_type(c, bool)

# Complex boolean expressions
d = (1 > 0) and (2 > 1)
assert_type(d, bool)

e = not (1 == 2)
assert_type(e, bool)
