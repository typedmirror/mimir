from typing import assert_type, Set

# Set annotation
s: Set[int] = {1, 2, 3}
assert_type(s, Set[int])

# Wrong element type
bad: Set[str] = {1, 2, 3}  # E[T001]
