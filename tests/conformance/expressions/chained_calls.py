from typing import assert_type

# Nested function calls
result = len(str(42))
assert_type(result, int)

# Chained string methods
upper_stripped = "  hello  ".strip().upper()
assert_type(upper_stripped, str)

# Negative indexing
lst = [1, 2, 3]
last = lst[-1]
assert_type(last, int)
