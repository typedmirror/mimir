from typing import assert_type

names = ["alice", "bob"]

# Dict comprehension infers key and value types
d = {n: len(n) for n in names}
assert_type(d, dict[str, int])
