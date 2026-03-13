from typing import assert_type

# List concatenation preserves element type
a = [1, 2] + [3, 4]
assert_type(a, list[int])

# len on various containers
assert_type(len([1, 2, 3]), int)
assert_type(len("hello"), int)
assert_type(len({"a": 1}), int)
assert_type(len((1, 2)), int)
