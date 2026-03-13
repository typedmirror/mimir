from typing import assert_type

# List repetition with bool elements
flags = [False] * 10
assert_type(flags, list[bool])
