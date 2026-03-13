from typing import assert_type

# Walrus operator type inference
if (n := 42) > 0:
    assert_type(n, int)

# Walrus with string
if (s := "hello"):
    assert_type(s, str)
