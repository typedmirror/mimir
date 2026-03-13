from typing import assert_type, List

# For loop variable gets element type
items: List[str] = ["a", "b", "c"]

for item in items:
    assert_type(item, str)

# Nested for loops
matrix: List[List[int]] = [[1, 2], [3, 4]]
for row in matrix:
    assert_type(row, List[int])

# Wrong type from iteration
for s in items:
    bad: int = s  # E
