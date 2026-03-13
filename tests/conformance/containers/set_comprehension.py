from typing import assert_type

xs = [1, 2, 3]

# Set comprehension infers element type from iterable
ss = {x for x in xs}
assert_type(ss, set[int])
