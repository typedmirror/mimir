from typing import assert_type, cast, Union

x: Union[int, str] = 42

# Cast to int
y = cast(int, x)
assert_type(y, int)

# Cast to str
z = cast(str, x)
assert_type(z, str)

# Cast with simple value
w = cast(float, 42)
assert_type(w, float)
