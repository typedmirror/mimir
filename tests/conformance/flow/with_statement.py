from typing import assert_type

# Variable types preserved through with block
x: int = 0
with open("test.txt") as f:
    x = 42
assert_type(x, int)
