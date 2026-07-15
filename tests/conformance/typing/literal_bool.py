# Literal bool validation

from typing import Literal

def set_flag(v: Literal[True]) -> None:
    pass

set_flag(True)   # OK
set_flag(False)  # E[T002]: Incompatible argument type
