from typing import assert_type

# Numeric promotion
a = 1 + 2.0
b = 1 + 2
c = "hi" + "!"

# Correct
assert_type(a, float)
assert_type(b, int)
assert_type(c, str)

# Wrong
assert_type(a, int)  # E[T006]
assert_type(b, float)  # E[T006]
assert_type(c, int)  # E[T006]
