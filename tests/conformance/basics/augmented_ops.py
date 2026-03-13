from typing import assert_type

# Augmented string concatenation preserves type
s: str = "hello"
s += " world"
assert_type(s, str)

# Augmented int arithmetic preserves type
n: int = 10
n += 5
n -= 3
n *= 2
assert_type(n, int)

# Augmented float
f: float = 1.0
f += 0.5
assert_type(f, float)
