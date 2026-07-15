from typing import assert_type

# Bool arithmetic promotes to int (Python semantics)
a = True + True
b = True + 1
c = True * False
d = True - False

# Correct
assert_type(a, int)
assert_type(b, int)
assert_type(c, int)
assert_type(d, int)

# Wrong
assert_type(a, bool)  # E[T006]
assert_type(b, bool)  # E[T006]
assert_type(c, bool)  # E[T006]
