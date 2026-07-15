from typing import assert_type

# bytes type annotation
b: bytes = b"hello"
assert_type(b, bytes)

# Wrong type assigned to bytes
bad: bytes = "not bytes"  # E[T001]
