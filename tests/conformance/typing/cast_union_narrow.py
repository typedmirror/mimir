from typing import assert_type, Union, cast

# Cast extracts from union
x: Union[int, str] = 42
r = cast(int, x)
assert_type(r, int)

y: Union[float, str] = "hello"
r2 = cast(str, y)
assert_type(r2, str)

# Cast wrong type
bad: int = cast(str, x)  # E
