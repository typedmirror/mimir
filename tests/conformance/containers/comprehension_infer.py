from typing import assert_type

# List comprehension infers list type
r1 = [x * 2 for x in range(5)]
assert_type(r1, list)

# Dict comprehension infers dict type
r2 = {k: v for k, v in {"a": 1}.items()}
assert_type(r2, dict)

# Set comprehension infers set type
r3 = {x for x in [1, 2, 3]}
assert_type(r3, set)
