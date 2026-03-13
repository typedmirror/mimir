from typing import Union, assert_type

# Union accepts any member type
x: Union[int, str] = 42
x = "hello"  # OK: str is member

y: int | str | float = 42
y = "hello"
y = 3.14

# Non-member assignment
z: Union[int, str] = 3.14  # E

# Union in function params
def check(val: int | str) -> None:
    pass

check(42)
check("hi")
check(3.14)  # E
