from typing import Set, assert_type

# Set type annotation
s: Set[int] = {1, 2, 3}

# Set element type wrong
bad: Set[str] = {1, 2, 3}  # E[T001]

# Set with correct element type
s2: Set[str] = {"a", "b", "c"}
assert_type(s2, Set[str])
