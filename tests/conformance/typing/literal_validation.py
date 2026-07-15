# Literal type validation — invalid constant rejected

from typing import Literal

def handle(mode: Literal["read", "write"]) -> None:
    pass

handle("read")    # OK
handle("write")   # OK
handle("delete")  # E[T002]: Incompatible argument type

def set_level(n: Literal[1, 2, 3]) -> None:
    pass

set_level(1)   # OK
set_level(99)  # E[T002]: Incompatible argument type
