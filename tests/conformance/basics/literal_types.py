from typing import assert_type

# Each literal infers its type
r1 = 42
assert_type(r1, int)

r2 = "hello"
assert_type(r2, str)

r3 = 3.14
assert_type(r3, float)

r4 = True
assert_type(r4, bool)

r5 = None

r6 = b"bytes"
assert_type(r6, bytes)

r7 = [1, 2, 3]
assert_type(r7, list)

r8 = {"a": 1}
assert_type(r8, dict)

r9 = (1, 2, 3)
assert_type(r9, tuple)

r10 = {1, 2, 3}
assert_type(r10, set)
