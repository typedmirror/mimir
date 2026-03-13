from typing import assert_type

xs = [1, 2, 3]

# List comprehension infers element type from iterable
ys = [x for x in xs]
assert_type(ys, list[int])
