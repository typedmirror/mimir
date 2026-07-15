from typing import assert_type

# is / is not returns bool
r1 = None is None
assert_type(r1, bool)

r2 = 42 is not None
assert_type(r2, bool)

# Wrong type from identity check
bad: str = None is None  # E[T001]
