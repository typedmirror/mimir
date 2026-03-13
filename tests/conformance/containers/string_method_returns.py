from typing import assert_type

s = "hello world"

# str methods that return str
upper = s.upper()
assert_type(upper, str)

lower = s.lower()
assert_type(lower, str)

stripped = s.strip()
assert_type(stripped, str)

replaced = s.replace("hello", "goodbye")
assert_type(replaced, str)

# str methods that return list[str]
parts = s.split(" ")
assert_type(parts, list[str])

# str methods that return int
idx = s.find("world")
assert_type(idx, int)

count = s.count("l")
assert_type(count, int)

# str methods that return bool
starts = s.startswith("hello")
assert_type(starts, bool)

ends = s.endswith("world")
assert_type(ends, bool)

is_alpha = s.isalpha()
assert_type(is_alpha, bool)

# join returns str
joined = ", ".join(["a", "b", "c"])
assert_type(joined, str)
