from typing import assert_type

# Type aliases
MyInt = int
MyStr = str
MyFloat = float

x: MyInt = 42
assert_type(x, int)

y: MyStr = "hello"
assert_type(y, str)

z: MyFloat = 3.14
assert_type(z, float)

# Wrong type via alias
bad: MyInt = "wrong"  # E[T001]
