from typing import assert_type

# All augmented assignment operators preserve int
x = 10
x += 5
assert_type(x, int)
x -= 3
assert_type(x, int)
x *= 2
assert_type(x, int)
x //= 3
assert_type(x, int)
x %= 7
assert_type(x, int)
x **= 2
assert_type(x, int)
