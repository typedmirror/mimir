from typing import assert_type

# Int + float = float
r1 = 1 + 2.0
assert_type(r1, float)

# Int + int = int
r2 = 1 + 2
assert_type(r2, int)

# Bool + int = int (bool promotes)
r3 = True + 1
assert_type(r3, int)

# Float * int = float
r4 = 2.0 * 3
assert_type(r4, float)

# String * int = str
r5 = "ha" * 3
assert_type(r5, str)

# Can't add str + int
bad = "hello" + 42  # E[T005]
