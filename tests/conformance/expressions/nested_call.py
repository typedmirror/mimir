from typing import assert_type

# Nested function calls — type flows through
r1 = len(str(42))
assert_type(r1, int)

r2 = str(len([1, 2, 3]))
assert_type(r2, str)

# Wrong type from nested call
bad: str = len("hello")  # E[T001]
