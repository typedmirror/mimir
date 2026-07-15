from typing import assert_type

# Valid augmented assignments
s = "hello"
s += " world"
assert_type(s, str)

f = 1.0
f += 2.0
assert_type(f, float)

n = 10
n -= 3
assert_type(n, int)

# Invalid: int += str
x: int = 5
x += "bad"  # E[T005]
