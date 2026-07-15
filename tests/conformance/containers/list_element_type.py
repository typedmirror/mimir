from typing import List, assert_type

# List element type via subscript
xs: List[int] = [1, 2, 3]
elem = xs[0]
assert_type(elem, int)

# List with string elements
names: List[str] = ["a", "b"]
name = names[0]
assert_type(name, str)

# Wrong element type assignment
bad: str = xs[0]  # E[T001]
