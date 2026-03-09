from typing import Optional, Union
# Optional[T] = T | None
x: Optional[int] = None
x2: Optional[int] = 42
# Union types
y: Union[int, str] = 42
y2: Union[int, str] = "hello"
# PEP 604 syntax
z: int | str = 42
z2: int | str = "hello"
z3: int | None = None
# Errors
bad1: Optional[int] = "hello"  # E
bad2: Union[int, str] = 3.14   # E
bad3: int | str = 3.14         # E
