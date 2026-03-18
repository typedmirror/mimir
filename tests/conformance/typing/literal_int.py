# Literal int validation

from typing import Literal

def set_level(n: Literal[1, 2, 3]) -> None:
    pass

set_level(1)   # OK
set_level(99)  # E: Incompatible argument type
