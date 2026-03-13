from typing import assert_type, Tuple

# Tuple annotation with types
t: Tuple[int, str, float] = (1, "hello", 3.14)
assert_type(t, Tuple[int, str, float])

# Wrong tuple type
bad: Tuple[int, int] = (1, "hello")  # E
