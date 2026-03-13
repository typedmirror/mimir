from typing import assert_type, Union

# Each member type assignable to union
a: Union[int, str] = 42
b: Union[int, str] = "hello"

# Non-member rejected
bad: Union[int, str] = [1, 2]  # E
