from typing import assert_type

# Tuple unpacking from literal
a, b, c = (1, "hello", 3.14)
assert_type(a, int)
assert_type(b, str)
assert_type(c, float)

# Nested tuple
nested = ((1, 2), (3, 4))
assert_type(nested, tuple[tuple[int, int], tuple[int, int]])

# Tuple annotation mismatch
bad: tuple[int, str] = (1, 2)  # E
