from typing import assert_type

# Boolean operations
r1 = True and False
assert_type(r1, bool)

r2 = True or False
assert_type(r2, bool)

r3 = not True
assert_type(r3, bool)

# Comparison chain returns bool
r4 = 1 < 2
assert_type(r4, bool)

r5 = "a" == "b"
assert_type(r5, bool)

r6 = 1 != 2
assert_type(r6, bool)
