from typing import assert_type

# String method return type flows through chain
r1 = "hello".upper()
assert_type(r1, str)

# Two-level chain
r2 = "Hello World".lower().strip()
assert_type(r2, str)

# Chain ending with split (returns list)
r3 = "a,b,c".split(",")
assert_type(r3, list)

# Wrong type from string chain
bad: int = "hello".upper()  # E
