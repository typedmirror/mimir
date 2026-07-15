from typing import assert_type, List

# List method return types
items: List[str] = ["a", "b", "c"]

# Index returns element type
r1 = items[0]
assert_type(r1, str)

# Count returns int
r2 = items.count("a")
assert_type(r2, int)

# Wrong type from subscript
bad: int = items[0]  # E[T001]
