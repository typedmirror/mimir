from typing import assert_type, Optional

# Same-type ternary
x = 5
result1 = "yes" if x > 0 else "no"
assert_type(result1, str)

# Int ternary
result2 = 1 if True else 0
assert_type(result2, int)

# Ternary with None produces Optional
maybe = "hello" if True else None
assert_type(maybe, Optional[str])

# Mixed numeric ternary
num = 1 if True else 3.14
