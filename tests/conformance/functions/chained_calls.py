from typing import assert_type

# Method chaining — type flows through each return
r1 = "  Hello World  ".strip().lower().split()
assert_type(r1, list)

# Two-step chain
r2 = "hello".upper()
assert_type(r2, str)

# Three-step chain on variable
s: str = "test data"
r3 = s.replace("t", "T").upper()
assert_type(r3, str)

# Chain ending with different return type
r4 = "hello world".split()
assert_type(r4, list)

# Wrong type from chain
bad: int = "hello".upper()  # E[T001]
