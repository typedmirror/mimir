from typing import assert_type

# range() returns a list in mimir's model
r = range(10)
assert_type(r, list)

# range with start, stop
r2 = range(1, 10)
assert_type(r2, list)

# range with start, stop, step
r3 = range(0, 10, 2)
assert_type(r3, list)
