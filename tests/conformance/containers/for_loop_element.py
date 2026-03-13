from typing import assert_type

# List iteration
for x in [1, 2, 3]:
    assert_type(x, int)

# String iteration
for c in "hello":
    assert_type(c, str)

# Dict key iteration
d = {"a": 1, "b": 2}
for k in d:
    assert_type(k, str)

# Range iteration
for i in range(10):
    assert_type(i, int)
