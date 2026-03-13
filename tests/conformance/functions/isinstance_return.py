from typing import assert_type

# isinstance() always returns bool
r1 = isinstance(42, int)
assert_type(r1, bool)

r2 = isinstance("hello", str)
assert_type(r2, bool)

r3 = isinstance([], list)
assert_type(r3, bool)
