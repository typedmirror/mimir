from typing import assert_type

# .format() returns str
r1 = "Hello, {}!".format("world")
assert_type(r1, str)

# .join() returns str
r2 = ", ".join(["a", "b", "c"])
assert_type(r2, str)

# .startswith() returns bool
r3 = "hello".startswith("he")
assert_type(r3, bool)

# .endswith() returns bool
r4 = "hello".endswith("lo")
assert_type(r4, bool)

# Wrong type from string method
bad: int = "hello".upper()  # E[T001]
