from typing import Optional, assert_type

# Optional[T] is Union[T, None]
def check(x: Optional[int]) -> int:
    if x is not None:
        assert_type(x, int)
        return x
    return 0

# Optional param accepts None
def greet(name: Optional[str]) -> str:
    if name is not None:
        return name
    return "stranger"

greet("Alice")
greet(None)

# Wrong type for Optional[int]
def bad(x: Optional[int]) -> None:
    pass

bad("hello")  # E
