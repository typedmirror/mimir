from typing import cast
# cast returns the target type without checking
x: int = cast(int, "not_really_int")
y: str = cast(str, 42)
z: list[int] = cast(list[int], [])
