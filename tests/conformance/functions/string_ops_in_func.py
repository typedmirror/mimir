from typing import assert_type

# String method return types in function scope
def string_ops():
    s = "hello world"
    parts = s.split(" ")
    assert_type(parts, list[str])
    upper = s.upper()
    assert_type(upper, str)
    joined = ", ".join(["a", "b", "c"])
    assert_type(joined, str)
