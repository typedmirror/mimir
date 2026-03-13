from typing import assert_type

# F-string always returns str
name = "world"
r1 = f"hello {name}"
assert_type(r1, str)

num = 42
r2 = f"value: {num}"
assert_type(r2, str)

# F-string with expression
r3 = f"double: {num * 2}"
assert_type(r3, str)

# F-string assigned to wrong type
bad: int = f"hello"  # E
