from typing import Any, assert_type

# Any accepts anything
x: Any = 42
x = "hello"
x = [1, 2, 3]
x = None

# Any assignable to any specific type
def takes_any(val: Any) -> None:
    pass

takes_any(42)
takes_any("hello")
takes_any(None)

# Function returning Any
def get_thing() -> Any:
    return 42

r = get_thing()
# Any is assignable to int
y: int = r
z: str = r
