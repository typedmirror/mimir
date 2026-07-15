from typing import assert_type, List

# String method return types
s = "hello world"

r1 = s.upper()
assert_type(r1, str)

r2 = s.lower()
assert_type(r2, str)

r3 = s.split()
assert_type(r3, List[str])

r4 = s.strip()
assert_type(r4, str)

r5 = s.replace("hello", "hi")
assert_type(r5, str)

r6 = s.startswith("hello")
assert_type(r6, bool)

r7 = s.endswith("world")
assert_type(r7, bool)

r8 = s.find("world")
assert_type(r8, int)

# Wrong type from method
bad1: int = s.upper()  # E[T001]
bad2: str = s.find("x")  # E[T001]
