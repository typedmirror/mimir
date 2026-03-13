from typing import cast, assert_type

# cast returns the target type
x: object = 42
y = cast(int, x)
assert_type(y, int)

z = cast(str, 42)
assert_type(z, str)

# cast result assignable to annotated var
w: float = cast(float, "3.14")
assert_type(w, float)

# Wrong assignment of cast result
bad: str = cast(int, "42")  # E
