from typing import assert_type

xs = [1, 2, 3]

# Comprehension with arithmetic expression
doubled = [x * 2 for x in xs]
assert_type(doubled, list[int])

# Comprehension with method call
words = ["hello", "world"]
uppers = [w.upper() for w in words]
assert_type(uppers, list[str])

# Comprehension with filter
evens = [x for x in xs if x % 2 == 0]
assert_type(evens, list[int])
